// V15ParityEntries.swift - C4-4 D-2: the envelope's files and outputs matched by role and digest (CHTC C4 lane W)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One input or output of a V15-S5 step of the adopted record, with the step it belongs to. An adopted `files` or `outputs` entry
/// that no Mac entry matches passes only when one of these has its role and digest (ARCH A-D2-3, BIO B-D2-2), and for an output
/// of the step also its path (C4-5 E-1, BIO B-E1-1).
struct V15AdoptOnlyInput {
    let step: String
    let entry: [String: Any]
    /// True when the step lists the entry in its `outputs` (C4-5 E-1), false when it lists it in its `inputs` (C4-4 D-2).
    var isOutput = false

    /// The inputs and the outputs of each decompressor step, found by the step's role and never by a path pattern or an index.
    static func inputs(of roles: V15StepRoles) -> [V15AdoptOnlyInput] {
        var number = 0
        var found: [V15AdoptOnlyInput] = []
        for step in roles.steps {
            guard let id = step["id"] as? String, roles.role(ofID: id) == V15Roles.decompressor else { continue }
            number += 1
            let name = "\(V15Roles.decompressor)#\(number)"
            for entry in step["inputs"] as? [[String: Any]] ?? [] {
                found.append(V15AdoptOnlyInput(step: name, entry: entry))
            }
            for entry in step["outputs"] as? [[String: Any]] ?? [] {
                found.append(V15AdoptOnlyInput(step: name, entry: entry, isOutput: true))
            }
        }
        return found
    }

    /// Whether this step entry excuses an adopted entry that no Mac entry matches. An input matches on role and digest (BIO B-D2-2).
    /// An output matches on role, digest and path, all present, since both entries come from the adopted route and the path is
    /// the raw one (BIO B-E1-1).
    func excuses(role: String, _ adopted: [String: Any]) -> Bool {
        let digest = entry["checksumSHA256"] as? String
        guard entry["role"] as? String == role, digest == adopted["checksumSHA256"] as? String else { return false }
        guard isOutput else { return true }
        let path = entry["path"] as? String
        return digest != nil && path != nil && path == adopted["path"] as? String
    }
}

extension V15RouteNames {
    /// The payload paths one route's own envelope names (C4-4 D-5; ARCH A-D5-2, QA Q4-12): the published payload, the file the
    /// writer step redirects its output to (the node's `out/<payload>`, a Mac import's staged copy) and the file the statistics
    /// step reads (the node's `out/<payload>`, a Mac import's building-folder copy). Each is read from a step's `argv`, never
    /// matched by a pattern, so a path no record of the route names stays byte for byte.
    static func namedPayloadPaths(in envelope: [String: Any]) -> Set<String> {
        var paths = Set<String>()
        if let published = (envelope["output"] as? [String: Any])?["path"] as? String { paths.insert(published) }
        for step in envelope["steps"] as? [[String: Any]] ?? [] {
            let argv = step["argv"] as? [String] ?? []
            switch step["toolName"] as? String {
            case "bgzip":
                if let redirect = argv.lastIndex(of: ">"), argv.indices.contains(redirect + 1) { paths.insert(argv[redirect + 1]) }
            case "seqkit":
                if argv.dropFirst().first == "stats", let last = argv.last { paths.insert(last) }
            default:
                break
            }
        }
        return paths
    }

    /// The placeholder for a payload path as a whole token or after `key=`, or nil for any other token (SWIFT SW4-10).
    func payloadToken(_ token: String) -> String? {
        if payloadPaths.contains(token) { return Self.payloadPlaceholder }
        if let equals = token.firstIndex(of: "="), payloadPaths.contains(String(token[token.index(after: equals)...])) {
            return String(token[...equals]) + Self.payloadPlaceholder
        }
        return nil
    }
}

extension V15Comparison {
    /// One entry of an envelope's `files` or `outputs` and what it matches on.
    private struct Entry {
        let object: [String: Any]
        let role: String
        /// The role and the SHA-256, or the stripped path for an entry whose digest XC-1 or D-4 never compares.
        let key: String
        let stripped: String
    }

    private func entries(_ list: [Any], route: V15Route) -> [Entry] {
        list.compactMap { value in
            guard let object = value as? [String: Any] else { return nil }
            let role = object["role"] as? String ?? ""
            let stripped = Self.stripRoot(object["path"] as? String ?? "", roots: roots[route] ?? [], names: names[route] ?? V15RouteNames())
            // XC-1 (the stored payload and each file that holds it) and D-4 (the reports) never compare a digest across routes.
            let exempt = isPayloadFile(object) || isReportFile(object)
            let token = exempt ? "path " + stripped : "sha256 " + (object["checksumSHA256"] as? String ?? "")
            return Entry(object: object, role: role, key: role + "\u{1F}" + token, stripped: stripped)
        }
    }

    /// C4-4 D-2 (SWIFT SW4-4, ARCH A-D2-1 to A-D2-3, BIO B-D2-1 and B-D2-2, QA Q4-4): the entries of the run's `files` or
    /// `outputs` pair one to one as a multiset on role and SHA-256, never by index, and a pair then compares as the walk
    /// compares any object. An entry that pairs with nothing is one finding with its path, role and digest, unless an input of
    /// a V15-S5 step has its role and digest as an input, or its role, digest and path as an output (C4-5 E-1; reported, one step
    /// entry for one entry of each list), and an entry of each route with one role and path but two digests is one finding.
    mutating func compareEntries(_ adopted: [Any], _ mac: [Any], path: [String]) {
        var macPool = entries(mac, route: .mac)
        var unmatched: [Entry] = []
        var pairs: [(adopted: Entry, mac: Entry)] = []
        for entry in entries(adopted, route: .adopted) {
            let index = macPool.firstIndex { $0.key == entry.key && $0.stripped == entry.stripped }
                ?? macPool.firstIndex { $0.key == entry.key }
            if let index { pairs.append((entry, macPool.remove(at: index))) } else { unmatched.append(entry) }
        }
        var excusers = adoptOnlyInputs
        for entry in unmatched {
            let name = Self.joined(path + ["[\(entry.role) \(entry.stripped)]"])
            if let index = macPool.firstIndex(where: { $0.role == entry.role && $0.stripped == entry.stripped }) {
                let partner = macPool.remove(at: index)
                findings.append(V15Finding(key: name, adopted: Self.describe(entry.object), mac: Self.describe(partner.object),
                                           why: "D-2: the entry's role and path match on both routes and its digest or size differs"))
            } else if let index = excusers.firstIndex(where: { $0.excuses(role: entry.role, entry.object) }) {
                let step = excusers.remove(at: index).step
                reported.append("PARITY-REPORTED line=V15-S5 key=\(name) step=\(step) \(Self.describe(entry.object))")
            } else {
                findings.append(V15Finding(
                    key: name, adopted: Self.describe(entry.object), mac: "absent",
                    why: "D-2: an entry only the adopt route holds: no Mac entry has its role and digest (or its role and path, for a digest "
                        + "XC-1 or D-4 never compares), and no V15-S5 step names it as an input or an output"))
            }
        }
        for entry in macPool {
            findings.append(V15Finding(
                key: Self.joined(path + ["[\(entry.role) \(entry.stripped)]"]), adopted: "absent", mac: Self.describe(entry.object),
                why: "D-2: an entry only the Mac route holds: no adopted entry has its role and digest (or its role and path, for a digest "
                    + "XC-1 or D-4 never compares)"))
        }
        for pair in pairs {
            walk(pair.adopted.object, pair.mac.object, path: path + ["[\(pair.adopted.role) \(pair.adopted.stripped)]"])
        }
    }

    /// An entry as a finding prints it: the raw path, role, digest and size.
    static func describe(_ object: [String: Any]) -> String {
        "path=\(render(object["path"])) role=\(render(object["role"])) sha256=\(render(object["checksumSHA256"])) size=\(render(object["fileSize"]))"
    }

    /// QA Q4-13 (XC-1, integrity inside one route): every entry of a route at one of its payload paths, in the run's files and
    /// outputs and in each step's inputs and outputs, carries the digest of that route's own payload.
    static func payloadIntegrityFindings(envelope: [String: Any], route: V15Route, paths: Set<String>) -> [V15Finding] {
        guard let payload = (envelope["output"] as? [String: Any])?["checksumSHA256"] as? String else {
            return [V15Finding(key: "envelope.output.checksumSHA256", adopted: route == .adopted ? "absent" : "-", mac: route == .mac ? "absent" : "-",
                               why: "the \(route.rawValue) envelope names no payload digest (QA Q4-13)")]
        }
        var lists: [(name: String, entries: [[String: Any]])] = [
            ("files", envelope["files"] as? [[String: Any]] ?? []), ("outputs", envelope["outputs"] as? [[String: Any]] ?? []),
        ]
        for step in envelope["steps"] as? [[String: Any]] ?? [] {
            let tool = step["toolName"] as? String ?? "step"
            lists.append(("steps[\(tool)].inputs", step["inputs"] as? [[String: Any]] ?? []))
            lists.append(("steps[\(tool)].outputs", step["outputs"] as? [[String: Any]] ?? []))
        }
        var found: [V15Finding] = []
        for list in lists {
            for entry in list.entries {
                guard let path = entry["path"] as? String, paths.contains(path) else { continue }
                let digest = entry["checksumSHA256"] as? String ?? "absent"
                if digest != payload {
                    found.append(V15Finding(
                        key: "envelope.\(list.name)", adopted: route == .adopted ? digest : "-", mac: route == .mac ? digest : "-",
                        why: "QA Q4-13: the \(route.rawValue) route's entry at its payload path \(path) holds \(digest), and the route's payload is \(payload)"))
                }
            }
        }
        return found
    }
}

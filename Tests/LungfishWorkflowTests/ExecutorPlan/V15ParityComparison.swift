// V15ParityComparison.swift - The one comparison of an adopted bundle with a Mac import under the V15 list (CHTC C4 lane P)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
@testable import LungfishPortable
@testable import LungfishWorkflow

/// One line the comparison failed on, with both values and why.
struct V15Finding: Sendable, CustomStringConvertible {
    let key: String
    let adopted: String
    let mac: String
    let why: String
    /// The artifact files the values were read from, as `keepArtifacts` names them (QV-27).
    var artifact = ""
    /// Both values whole and before any root is stripped, for a finding whose shown values are cut or stripped (QV-27).
    var raw: (adopted: String, mac: String)?

    var description: String {
        var text = "PARITY-FINDING key=\(key) adopted=\(adopted) mac=\(mac) why=\(why)"
        if !artifact.isEmpty { text += " artifact=\(artifact)" }
        if let raw { text += " rawAdopted=\(raw.adopted) rawMac=\(raw.mac)" }
        return text
    }
}

/// What C4-3 C-2 maps for one route besides its roots: its one work stem, read from its own record; the node's `work/`
/// folder; whether its fastp report names carry a per-run UUID (the Mac's); and each input path its own records name,
/// to its mate by the plan's digest. The placeholders exist only here and never reach a record (UX U-3).
struct V15RouteNames: Sendable, Equatable {
    static let stemPlaceholder = "<work-stem>"
    static let matePlaceholderPrefix = "<input:"
    var stem: String?
    var workFolder: String?
    var reportUUID = false
    var inputs: [String: String] = [:]
    /// The payload's paths this route's own record names (C4-4 D-5): the published payload, a Mac import's staged and
    /// building copies and the node's `out/<payload>`, each read from that route's envelope. A token of `argv` that equals
    /// one maps to `payloadPlaceholder`, whole or after `key=`, and no other token of any key does.
    var payloadPaths: Set<String> = []
    static let payloadPlaceholder = "<payload>"

    /// Each path to `<input:R1>` or `<input:R2>` when its digest equals exactly one mate's digest in the plan's order
    /// (BIO B3-5, QA Q-2e, SWIFT C-2). A path whose digest matches no mate, and every path of a plan whose mates share a
    /// digest, maps to nothing, so it stays byte for byte and fails against the other route's mate.
    static func mates(_ digests: [String: String], plan mates: [String]) -> [String: String] {
        guard !mates.isEmpty, Set(mates).count == mates.count else { return [:] }
        var mapped: [String: String] = [:]
        for (path, digest) in digests {
            if let index = mates.firstIndex(of: digest) { mapped[path] = matePlaceholderPrefix + "R\(index + 1)>" }
        }
        return mapped
    }

    /// A payload's stem, its file name without `.fastq.gz`, or nil for any other name.
    static func stem(ofPayload path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".fastq.gz") && name.count > 9 ? String(name.dropLast(9)) : nil
    }
}

/// SWIFT's S-4: each record's JSON tree walked key by key against the closed list.
struct V15Comparison {
    /// The roots `stripRoot` removes from a path token, for each route (XC-10).
    var roots: [V15Route: [String]]
    /// The last path components of the payload and of the files that hold its values (XC-1).
    var payloadFileNames: Set<String>
    var findings: [V15Finding] = []
    var reported: [String] = []
    /// C4-4 D-2: the inputs of the adopted record's V15-S5 steps, the only unmatched `files` entries that pass.
    var adoptOnlyInputs: [V15AdoptOnlyInput] = []

    init(roots: [V15Route: [String]], payloadFileNames: Set<String>) {
        self.roots = roots
        self.payloadFileNames = payloadFileNames
    }

    // MARK: The one function of XC-10 B as amended by C4-3 C-2

    /// The names C4-3 C-2 maps for each route besides its roots.
    var names: [V15Route: V15RouteNames] = [:]

    static let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// Strips a route's root from a path token, whether the path is the whole token or follows a key such as `in=`, to
    /// leave the plan's relative path, then maps C4-3 C-2's names. Nothing else rewrites a token.
    static func stripRoot(
        _ token: String, roots: [String], names: V15RouteNames = V15RouteNames(), mapsPayload: Bool = false
    ) -> String {
        if let mate = names.inputs[token] { return mate }
        // C4-4 D-5: a payload path of the route's own record maps in `argv` only (ARCH A-D5-2), whole or after `key=`.
        if mapsPayload, let mapped = names.payloadToken(token) { return mapped }
        var key = "", value = token
        for root in roots.sorted(by: { $0.count > $1.count }) where !root.isEmpty {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if token.hasPrefix(prefix) {
                value = String(token.dropFirst(prefix.count))
                break
            }
            if let equals = token.firstIndex(of: "="), token[token.index(after: equals)...].hasPrefix(prefix) {
                key = String(token[...equals])
                value = String(token[token.index(after: equals)...].dropFirst(prefix.count))
                break
            }
        }
        return key + mapNames(value, names)
    }

    /// C4-3 C-2's maps, each anchored: an input path whole, to its mate by digest; `work/` only as the first folder of a
    /// node token; the stem only as the leading `<stem>_` of the last path component; the Mac's report UUID only as the
    /// `_<UUID>` just before `.json` of a fastp report name. Every other text stays byte for byte.
    private static func mapNames(_ value: String, _ names: V15RouteNames) -> String {
        if let mate = names.inputs[value] { return mate }
        var path = value
        if let work = names.workFolder, !work.isEmpty, path.hasPrefix(work + "/") { path.removeFirst(work.count + 1) }
        let slash = path.lastIndex(of: "/")
        let folder = slash.map { String(path[...$0]) } ?? ""
        var last = slash.map { String(path[path.index(after: $0)...]) } ?? path
        if let stem = names.stem, !stem.isEmpty, last.hasPrefix(stem + "_") {
            last = V15RouteNames.stemPlaceholder + last.dropFirst(stem.count)
        }
        if names.reportUUID,
           let range = last.range(of: "_fastp_report_" + uuidPattern + "\\.json$", options: .regularExpression) {
            last = String(last[..<range.lowerBound]) + "_fastp_report.json"
        }
        return folder + last
    }

    /// The roots of each route (QV-10): the project, and on the adopt route the returned folder; on the Mac the one
    /// `.tmp/fastq-import-<UUID>` folder its records name, in its absolute and `@/` forms, and the storage root in its
    /// absolute and `<storage-root>` forms; on each route its one `.clumpify-split-<UUID>` folder below its work root.
    /// A route that names more than one such folder is a problem, since no one root would strip them all.
    static func routeRoots(
        project: String, returned: String, storageRoot: String?, macStrings: [String], adoptedStrings: [String]
    ) -> (roots: [V15Route: [String]], problems: [String]) {
        let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        var problems: [String] = []
        func one(_ pattern: String, _ strings: [String], _ what: String) -> String? {
            let found = folders(in: strings, matching: pattern)
            if found.count > 1 { problems.append("\(what) names \(found.count) folders, and must name one: \(found)") }
            return found.count == 1 ? found[0] : nil
        }
        let split = "\\.clumpify-split-" + uuid
        let scratch = one(NSRegularExpression.escapedPattern(for: project + "/.tmp/fastq-import-") + uuid, macStrings, "the Mac record's import folder")
        let macSplit = one(split, macStrings, "the Mac record's clumpify split folder")
        let adoptedSplit = one(split, adoptedStrings, "the adopted record's clumpify split folder")
        var mac = [project]
        if let scratch {
            let forms = [scratch, "@/" + scratch.dropFirst(project.count + 1)]
            mac += forms + (macSplit.map { split in forms.map { $0 + "/" + split } } ?? [])
        }
        if let storageRoot, !storageRoot.isEmpty { mac += [storageRoot, "<storage-root>"] }
        return ([.mac: mac, .adopted: [returned, project] + (adoptedSplit.map { [$0] } ?? [])], problems)
    }

    /// The distinct texts a pattern matches in a record's strings.
    static func folders(in strings: [String], matching pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found = Set<String>()
        for text in strings {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { found.insert(String(text[range])) }
            }
        }
        return found.sorted()
    }

    /// Every string value of a JSON tree, read from the parsed record so JSON escapes never hide a path.
    static func strings(in value: Any?) -> [String] {
        switch value {
        case let text as String: return [text]
        case let list as [Any]: return list.flatMap { strings(in: $0) }
        case let object as [String: Any]: return object.keys.sorted().flatMap { [$0] + strings(in: object[$0]) }
        default: return []
        }
    }

    /// QV-25: the envelope types an option as `{"type", "value"}`; a rule reads its value, JSON null for a typed null.
    static func untyped(_ value: Any?) -> Any? {
        guard let object = value as? [String: Any], object["type"] is String,
              Set(object.keys).isSubset(of: ["type", "value"]) else { return value }
        return object["value"] ?? NSNull()
    }

    // MARK: Records

    /// The envelopes, with the steps paired by role, plan order and tool id (QA ruling 2).
    mutating func compareEnvelopes(
        adopted: [String: Any], mac: [String: Any], adoptedRoles: V15StepRoles, macRoles: V15StepRoles, artifact: String = "",
        adoptedBundle: URL? = nil, macBundle: URL? = nil
    ) {
        adoptOnlyInputs = V15AdoptOnlyInput.inputs(of: adoptedRoles)
        let start = findings.count
        defer { for index in start..<findings.count { findings[index].artifact = artifact } }
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
        // C4-4 D-4: each paired step's report copies are read from the two bundles, parsed and compared.
        if let adoptedBundle, let macBundle {
            compareReportCopies(pairs: pairs, adoptedBundle: adoptedBundle, macBundle: macBundle)
        }
    }

    mutating func compareSidecars(adopted: [String: Any], mac: [String: Any], artifact: String = "") {
        let start = findings.count
        defer { for index in start..<findings.count { findings[index].artifact = artifact } }
        walk(adopted, mac, path: ["sidecar"])
    }

    mutating func compareStep(
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
        // C4-4 D-1 (SWIFT SW4-2, BIO B-D1-1): the walk reaches a key only when a route holds it, so an adopted step with no
        // peakMemoryBytes (the Mac has none either) is found here, and a value that is not above 0 is no peak.
        if let line = Self.line(for: path + ["peakMemoryBytes"], tag: nil), line.id == "V15-16" {
            let held = adopted["peakMemoryBytes"]
            let key = Self.joined(path + ["peakMemoryBytes"])
            if held == nil, mac["peakMemoryBytes"] == nil {
                findings.append(V15Finding(key: key, adopted: "absent", mac: "absent",
                                           why: "\(line.id) must be present on the adopted route: the node records each tool step's peak memory and the adopt carries it (C4-4 D-1)"))
            } else if let held, ((held as? NSNumber)?.doubleValue ?? 0) <= 0 {
                findings.append(V15Finding(key: key, adopted: Self.render(held), mac: Self.render(mac["peakMemoryBytes"]),
                                           why: "\(line.id) must be above 0 on the adopted route (C4-4 D-1)"))
            }
        }
        // XC-4: a Mac step that records no version fails and never passes as an unlisted key.
        let version = mac["toolVersion"] as? String
        if version == nil || version == "unknown" || version?.isEmpty == true {
            findings.append(V15Finding(key: Self.joined(path + ["toolVersion"]), adopted: Self.render(adopted["toolVersion"]),
                                       mac: Self.render(mac["toolVersion"]), why: "the Mac step records no version (XC-4)"))
        }
        // C4-3 C-4 and ARCH-X3 R-1: a step whose managedToolID V15-27 sets aside must name the environment of its own program or,
        // for a tool whose version the node read from the image manifest, the linux-64 lock entry that lists it.
        if Self.line(for: path + ["managedToolID"], tag: nil)?.id == "V15-27" {
            for (route, step) in [(V15Route.adopted, adopted), (.mac, mac)] {
                let program = (step["argv"] as? [String])?.first ?? ""
                let tool = Self.untyped((step["resolvedOptions"] as? [String: Any])?["tool"]) as? [String: Any]
                let held = Self.expectedManagedToolID(program: program, tool: tool)
                if held == nil || step["managedToolID"] as? String != held {
                    findings.append(V15Finding(key: Self.joined(path + ["managedToolID"]), adopted: Self.render(adopted["managedToolID"]),
                                               mac: Self.render(mac["managedToolID"]),
                                               why: "V15-27: the \(route.rawValue) value is not the envs/<id>/ of the step's program \(program) or the linux-64 lock entry that lists it at the version and build the image manifest gave"))
                }
            }
        }
        // QV-17: V15-02 sets the node tool's record aside, so its version must be the step's own.
        if let tool = Self.untyped((adopted["resolvedOptions"] as? [String: Any])?["tool"]) as? [String: Any] {
            let held = Self.untyped(tool["version"]) as? String
            if held != adopted["toolVersion"] as? String {
                findings.append(V15Finding(key: Self.joined(path + ["resolvedOptions", "tool", "version"]), adopted: Self.render(held),
                                           mac: Self.render(adopted["toolVersion"]),
                                           why: "V15-02 sets the node tool aside only when its version is the step's toolVersion (QV-17)"))
            }
        }
    }

    /// The linux-64 lock's tool entries, read from the lock file itself and never through the adopt's function (ARCH-X3 R-1): each
    /// entry's id, the executables it lists and the version and build of its `packageSpec`, `<channel>::<package>=<version>=<build>`.
    static let linux64LockEntries: [(id: String, executables: [String], version: String, build: String)] = {
        guard let file = try? ManagedToolLock.resourceURL(named: ManagedToolLock.linux64ResourceName),
              let data = try? Data(contentsOf: file),
              let lock = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tools = lock["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard let id = tool["id"] as? String, let executables = tool["executables"] as? [String],
                  let spec = tool["packageSpec"] as? String else { return nil }
            let fields = (spec.components(separatedBy: "::").last ?? "").components(separatedBy: "=")
            return fields.count == 3 ? (id, executables, fields[1], fields[2]) : nil
        }
    }()

    /// The id a step's program names, worked out from the step's own record (C4-3 C-4, ARCH-X3 R-1). The first arm is the
    /// `envs/<id>/` folder of a program `<root>/envs/<id>/bin/<tool>`. The second is for a tool whose version the node read from
    /// the image manifest: the one linux-64 lock entry that lists the program's file name and pins the tool's version and build.
    /// Nil for any other step, and for a program that more than one entry or none matches.
    static func expectedManagedToolID(program: String, tool: [String: Any]?) -> String? {
        let parts = program.split(separator: "/").map(String.init)
        if let envs = parts.lastIndex(of: "envs"), envs + 3 < parts.count, parts[envs + 2] == "bin" { return parts[envs + 1] }
        guard let tool, untyped(tool["versionSource"]) as? String == "imageManifest",
              let version = untyped(tool["version"]) as? String, let build = untyped(tool["build"]) as? String,
              let file = parts.last else { return nil }
        let entries = linux64LockEntries.filter { $0.executables.contains(file) && $0.version == version && $0.build == build }
        return entries.count == 1 ? entries[0].id : nil
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
            let fileTag = isPayloadFile(a) || isPayloadFile(m) ? "payload-file" : (isReportFile(a) || isReportFile(m) ? "report-file" : nil)
            for key in Set(a.keys).union(m.keys).sorted() {
                walk(a[key], m[key], path: path + [key], tag: fileTag)
            }
        case let (a as [Any], m as [Any]):
            // C4-4 D-2: the run's files and outputs match by role and digest, never by index.
            if path == ["envelope", "files"] || path == ["envelope", "outputs"] {
                compareEntries(a, m, path: path)
                return
            }
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

    private mutating func apply(_ line: V15Line, _ typedAdopted: Any?, _ typedMac: Any?, path: [String]) {
        let key = Self.joined(path)
        let adopted = Self.untyped(typedAdopted), mac = Self.untyped(typedMac)
        switch line.rule {
        case .path:
            let a = Self.stripped(adopted, roots: roots[.adopted] ?? [], names: names[.adopted] ?? V15RouteNames())
            let m = Self.stripped(mac, roots: roots[.mac] ?? [], names: names[.mac] ?? V15RouteNames())
            if !Self.equal(a, m) {
                var finding = V15Finding(key: key, adopted: Self.render(a), mac: Self.render(m),
                                         why: "\(line.id): the path differs byte for byte after the root is stripped (XC-10)")
                finding.raw = (Self.render(adopted, whole: true), Self.render(mac, whole: true))
                findings.append(finding)
            }
        case .notCompared(let mustCarry, let mustLack):
            for route in mustCarry where (route == .adopted ? adopted : mac) == nil {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "\(line.id) must be present on the \(route.rawValue) route"))
            }
            for route in mustLack where (route == .adopted ? adopted : mac) != nil {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "\(line.id) must be absent on the \(route.rawValue) route"))
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
            compareArgv(adopted, mac, key: key, mapsPayload: path.last == "argv")
        case .byRole:
            // Steps compare their ids in `compareStep`; an id outside a step is unlisted.
            if !Self.equal(adopted, mac) {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "an id outside a paired step, which the list does not name"))
            }
        }
    }

    private mutating func compareArgv(_ adopted: Any?, _ mac: Any?, key: String, mapsPayload: Bool) {
        // QV-14: a command line of several launches joined by ` && ` compares part by part, each part one argv.
        func parts(_ value: Any?) -> [[String]]? {
            if let list = value as? [String] { return [list] }
            if let text = value as? String {
                return text.components(separatedBy: " && ").map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
            }
            return nil
        }
        guard let a = parts(adopted), let m = parts(mac) else {
            if !(adopted == nil && mac == nil) {
                findings.append(V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                           why: "the argv is on one route only"))
            }
            return
        }
        // QV-27: a doubled slash in an absolute path is a path a tool could not have been given as the plan names it.
        for (route, list) in [(V15Route.adopted, a), (.mac, m)] {
            for token in list.joined() {
                let value = token.firstIndex(of: "=").map { String(token[token.index(after: $0)...]) } ?? token
                if value.hasPrefix("/") && value.contains("//") {
                    var finding = V15Finding(key: key, adopted: Self.render(adopted), mac: Self.render(mac),
                                             why: "an absolute path token on the \(route.rawValue) route holds //: \(token)")
                    finding.raw = (Self.render(adopted, whole: true), Self.render(mac, whole: true))
                    findings.append(finding)
                }
            }
        }
        let strippedA = a.map { $0.map { Self.stripRoot($0, roots: roots[.adopted] ?? [], names: names[.adopted] ?? V15RouteNames(), mapsPayload: mapsPayload) } }
        let strippedM = m.map { $0.map { Self.stripRoot($0, roots: roots[.mac] ?? [], names: names[.mac] ?? V15RouteNames(), mapsPayload: mapsPayload) } }
        var differs = strippedA.count != strippedM.count
        for (partA, partM) in zip(strippedA, strippedM) where !differs {
            differs = partA.count != partM.count
            for index in 0..<min(partA.count, partM.count) where !differs {
                if index == 0 {
                    differs = (partA[0] as NSString).lastPathComponent != (partM[0] as NSString).lastPathComponent
                } else {
                    differs = partA[index] != partM[index]
                }
            }
        }
        if differs {
            var finding = V15Finding(key: key, adopted: strippedA.description, mac: strippedM.description,
                                     why: "the argv differs token by token after the root is stripped (XC-10)")
            finding.raw = (Self.render(adopted, whole: true), Self.render(mac, whole: true))
            findings.append(finding)
        }
    }

    /// A value with the one function applied to each string in it, dictionary keys included.
    static func stripped(_ value: Any?, roots: [String], names: V15RouteNames = V15RouteNames()) -> Any? {
        switch value {
        case let text as String: return stripRoot(text, roots: roots, names: names)
        case let list as [Any]: return list.map { stripped($0, roots: roots, names: names) ?? NSNull() }
        case let object as [String: Any]:
            return Dictionary(object.map { (stripRoot($0.key, roots: roots, names: names), stripped($0.value, roots: roots, names: names) ?? NSNull()) },
                              uniquingKeysWith: { first, _ in first })
        default: return value
        }
    }

    func isPayloadFile(_ object: [String: Any]) -> Bool {
        guard object["checksumSHA256"] != nil || object["fileSize"] != nil, let path = object["path"] as? String else { return false }
        return payloadFileNames.contains((path as NSString).lastPathComponent)
    }

    // MARK: Matching and values

    static func line(for path: [String], tag: String?) -> V15Line? {
        V15ParityList.lines.first { line in
            line.patterns.contains { pattern in
                let parts = pattern.split(separator: ".").map(String.init)
                if let kind = parts.first, kind == "payload-file" || kind == "report-file" { return tag == kind && parts.last == path.last }
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

    /// A value as a finding prints it, cut at 240 characters unless `whole`.
    static func render(_ value: Any?, whole: Bool = false) -> String {
        let limit = whole ? Int.max : 240
        guard let value else { return "absent" }
        if value is NSNull { return "null" }
        if let text = value as? String { return "\"\(text.prefix(limit))\"" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(String(decoding: data, as: UTF8.self).prefix(limit))
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
            if kind == V15Roles.decompressor { result.roles[id] = V15Roles.decompressor }
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

    /// AMV1 BIO fix 3 (XC-9, QA ruling 3 condition 1): every value column of the node's table except `file` is compared. The
    /// columns that map to a key of the Mac's sidecar (`columns`, Q20 and Q30) are compared there. Each other column (format,
    /// type, Q1, Q3, sum_gap, N50_num, sum_n) is compared as text with the same column of a seqkit row of the Mac's own
    /// payload, since the Mac's sidecar keeps no value for it. A Mac table that holds no row is a finding, never a pass.
    static func compareTables(standardOutput: String, macTable: String) -> [V15Finding] {
        func parse(_ text: String) -> (header: [String], values: [String: String])? {
            let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            guard lines.count >= 2 else { return nil }
            let header = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let row = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return (header, Dictionary(zip(header, row).map { ($0, $1) }, uniquingKeysWith: { first, _ in first }))
        }
        // A node table that does not parse is `compare`'s finding.
        guard let node = parse(standardOutput) else { return [] }
        guard let mac = parse(macTable) else {
            return [V15Finding(key: "statistics.macTable", adopted: "\(node.header.count) columns", mac: "no seqkit row",
                               why: "no seqkit stats row of the Mac's payload to compare the unmapped columns with (XC-9)")]
        }
        let mapped = Set(columns.map(\.column)).union(["file", "Q20(%)", "Q30(%)"])
        return node.header.filter { !mapped.contains($0) }.compactMap { column in
            let adopted = node.values[column] ?? "absent"
            let macValue = mac.values[column] ?? "absent"
            return adopted == macValue ? nil : V15Finding(
                key: "statistics.\(column)", adopted: adopted, mac: macValue,
                why: "the node's seqkit stats value differs from a seqkit row of the Mac's payload; no sidecar key holds this column (XC-9)")
        }
    }

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

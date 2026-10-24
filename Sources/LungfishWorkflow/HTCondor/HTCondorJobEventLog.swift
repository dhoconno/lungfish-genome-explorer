// HTCondorJobEventLog.swift - One read of a job's classic event log after condor_wait returns (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A job's id in its event log, `cluster.process.subprocess`.
public struct HTCondorJobID: Sendable, Hashable, CustomStringConvertible {
    public let cluster: Int
    public let process: Int
    public let subprocess: Int

    public init(cluster: Int, process: Int, subprocess: Int = 0) {
        self.cluster = cluster
        self.process = process
        self.subprocess = subprocess
    }

    /// `cluster.process`, the form `condor_q` and `condor_history` take.
    public var description: String { "\(cluster).\(process)" }
}

/// One row of an event's `Partitionable Resources` table. HTCondor writes Disk in KiB (`KB`) and Memory in MiB (`MB`),
/// and a column it leaves empty is nil here.
public struct HTCondorResourceUse: Sendable, Equatable {
    /// The row's name without its unit, such as `Cpus`, `Disk`, `Memory` or `TimeExecute`.
    public let name: String
    /// The unit in the row's parentheses, such as `KB`, `MB` or `s`.
    public let unit: String?
    public let usage: Double?
    public let request: Double?
    public let allocated: Double?

    public init(name: String, unit: String?, usage: Double?, request: Double?, allocated: Double?) {
        self.name = name
        self.unit = unit
        self.usage = usage
        self.request = request
        self.allocated = allocated
    }
}

/// How a run ended, from its 005 event.
public enum HTCondorTermination: Sendable, Equatable {
    case exited(returnValue: Int)
    case signaled(signal: Int)
}

/// One event of the log: its first line and the lines below it, up to the `...` that ends it.
public struct HTCondorJobEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 001. The execute host's name (the alias in its address, else the address) and its slot.
        case executing(host: String, slotName: String?)
        /// 004. The job left the machine before it ended. `reason` is the event's `Reason:` line, such as
        /// `Job vacated by schedd`, after which HTCondor runs the job again, or `via condor_rm (by user ...)`, which a
        /// 009 event follows.
        case evicted(reason: String?)
        /// 005.
        case terminated(HTCondorTermination)
        /// 006. HTCondor's sample of the job's size.
        case imageSizeUpdated(imageSizeKB: Int64, memoryUsageMB: Int64?, residentSetSizeKB: Int64?)
        /// 009. `condor_rm`, or a policy that removed the job.
        case aborted(reason: String?)
        /// 012.
        case held(reason: String, code: Int?, subcode: Int?)
        /// 013.
        case released(reason: String?)
        /// Any other event, such as a submit or a file transfer, kept by its code only.
        case other
    }

    public let code: Int
    public let job: HTCondorJobID
    /// The event's time on the access point's clock. The log names no time zone (oconnor-ap4000 writes US Central
    /// time), so the reader takes the clock as UTC. A difference of two times is right except across a change of
    /// daylight saving time.
    public let time: Date
    public let kind: Kind
    /// The event's `Partitionable Resources` table (004 and 005), empty for the other events.
    public let resources: [HTCondorResourceUse]
    /// The lines below the event's first line, without their leading whitespace.
    public let detail: [String]
}

/// Where the job stood at its log's last event that changes it.
public enum HTCondorJobState: Sendable, Equatable {
    /// Submitted or released, and not running.
    case idle
    case running(host: String)
    /// Evicted, and waiting to run again.
    case evicted
    case held(reason: String, code: Int?, subcode: Int?)
    case removed(reason: String?)
    case ended(HTCondorTermination)
}

/// Why an event log was not read.
public enum HTCondorJobEventLogError: Error, Equatable, LocalizedError {
    case tooLarge(bytes: Int)
    case notText
    case noEvents
    case malformedEvent(line: Int, reason: String)
    case moreThanOneJob(first: HTCondorJobID, other: HTCondorJobID)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            return "The job event log holds \(bytes) bytes, more than the \(HTCondorJobEventLog.largestReadBytes) a job's log may."
        case .notText:
            return "The job event log is not UTF-8 text."
        case .noEvents:
            return "The job event log holds no event."
        case .malformedEvent(let line, let reason):
            return "Line \(line) of the job event log \(reason)"
        case .moreThanOneJob(let first, let other):
            return "The job event log names job \(first) and job \(other). Each job of a batch writes its own log."
        }
    }
}

/// A job's classic event log, read once after `condor_wait -wait 240 <log>` returns (C4-06, C4-design section 4).
///
/// The reader does not wait and does not poll: it reads what the log holds. Wall time is the 005 time less the last
/// 001 time before it, and the job's use of Cpus, Disk and Memory comes from the 005 event's `Partitionable Resources`
/// table (usage, request and allocation).
public struct HTCondorJobEventLog: Sendable, Equatable {
    /// The largest log the reader takes. A job of 72 hours writes a few hundred events.
    public static let largestReadBytes = 64 << 20

    public let job: HTCondorJobID
    public let events: [HTCondorJobEvent]

    /// Reads the log at `url` once. A file over `largestReadBytes` is refused by its size before any of it is read.
    public static func read(_ url: URL) throws -> HTCondorJobEventLog {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= largestReadBytes else { throw HTCondorJobEventLogError.tooLarge(bytes: size) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // One byte past the limit shows a log that grew since the size check, without reading the rest of the file.
        let data = try handle.read(upToCount: largestReadBytes + 1) ?? Data()
        guard data.count <= largestReadBytes else { throw HTCondorJobEventLogError.tooLarge(bytes: data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw HTCondorJobEventLogError.notText }
        return try HTCondorJobEventLog(text: text)
    }

    public init(text: String) throws {
        let events = try HTCondorJobEventLogParser.events(in: text)
        guard let first = events.first else { throw HTCondorJobEventLogError.noEvents }
        if let other = events.first(where: { $0.job != first.job }) {
            throw HTCondorJobEventLogError.moreThanOneJob(first: first.job, other: other.job)
        }
        self.job = first.job
        self.events = events
    }

    /// The job's state at the last event that changes it. An image-size update or a file transfer changes none.
    public var state: HTCondorJobState {
        for event in events.reversed() {
            switch event.kind {
            case .executing(let host, _): return .running(host: host)
            case .evicted: return .evicted
            case .terminated(let termination): return .ended(termination)
            case .aborted(let reason): return .removed(reason: reason)
            case .held(let reason, let code, let subcode): return .held(reason: reason, code: code, subcode: subcode)
            case .released: return .idle
            case .imageSizeUpdated, .other: continue
            }
        }
        return .idle
    }

    /// The 001 events, one each time the job started on a machine.
    public var executions: [HTCondorJobEvent] { events.filter { $0.code == 1 } }

    public var evictions: [HTCondorJobEvent] { events.filter { $0.code == 4 } }

    public var holds: [HTCondorJobEvent] { events.filter { $0.code == 12 } }

    /// The last 005 event.
    public var termination: HTCondorJobEvent? { events.last { $0.code == 5 } }

    /// The host of the last 001 event.
    public var host: String? {
        guard case .executing(let host, _)? = executions.last?.kind else { return nil }
        return host
    }

    /// The 005 time less the last 001 time before it, in seconds, or nil before the job ends.
    public var wallTimeSeconds: TimeInterval? {
        guard let end = events.lastIndex(where: { $0.code == 5 }),
              let start = events[..<end].lastIndex(where: { $0.code == 1 })
        else { return nil }
        return events[end].time.timeIntervalSince(events[start].time)
    }

    /// A row of the 005 event's `Partitionable Resources` table, such as `Cpus`, `Disk` or `Memory`.
    public func resource(_ name: String) -> HTCondorResourceUse? {
        termination?.resources.first { $0.name == name }
    }

    /// The largest image size of the 006 events, in KiB.
    public var peakImageSizeKB: Int64? {
        events.compactMap { event -> Int64? in
            guard case .imageSizeUpdated(let size, _, _) = event.kind else { return nil }
            return size
        }.max()
    }
}

/// The line rules of the classic event log.
enum HTCondorJobEventLogParser {
    /// `NNN (cluster.process.subprocess) YYYY-MM-DD HH:MM:SS text`, with HTCondor's optional `T`, sub-second and zone.
    private static let header = try! NSRegularExpression(
        pattern: #"^([0-9]{3}) \(([0-9]+)\.([0-9]+)\.([0-9]+)\) ([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:?[0-9]{2})?(?: (.*))?$"#
    )
    private static let eventStart = try! NSRegularExpression(pattern: #"^[0-9]{3} \("#)
    private static let normalTermination = try! NSRegularExpression(pattern: #"Normal termination \(return value (-?[0-9]+)\)"#)
    private static let abnormalTermination = try! NSRegularExpression(pattern: #"Abnormal termination \(signal ([0-9]+)\)"#)
    private static let holdCode = try! NSRegularExpression(pattern: #"^Code ([0-9]+) Subcode (-?[0-9]+)$"#)
    private static let sizeLine = try! NSRegularExpression(pattern: #"^([0-9]+) +- +(MemoryUsage|ResidentSetSize) of job"#)

    static func events(in text: String) throws -> [HTCondorJobEvent] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        var events: [HTCondorJobEvent] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line == "..." {
                index += 1
                continue
            }
            let lineNumber = index + 1
            var body: [String] = []
            index += 1
            // A log read while the job writes it may end inside an event, with no `...` after it.
            while index < lines.count, lines[index] != "..." {
                body.append(lines[index])
                index += 1
            }
            events.append(try event(line, body: body, lineNumber: lineNumber))
        }
        return events
    }

    private static func event(_ line: String, body: [String], lineNumber: Int) throws -> HTCondorJobEvent {
        guard let groups = captures(header, in: line) else {
            let reason = captures(eventStart, in: line) == nil
                ? "is not the first line of an event."
                : "names its time in a form the reader does not take (it takes YYYY-MM-DD HH:MM:SS)."
            throw HTCondorJobEventLogError.malformedEvent(line: lineNumber, reason: reason)
        }
        func number(_ index: Int) -> Int { Int(groups[index] ?? "") ?? 0 }
        let code = number(1)
        let job = HTCondorJobID(cluster: number(2), process: number(3), subprocess: number(4))
        guard let time = date(groups) else {
            throw HTCondorJobEventLogError.malformedEvent(line: lineNumber, reason: "names a time that is not a date.")
        }
        let headline = groups[13] ?? ""
        let detail = body.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let kind = try self.kind(code: code, headline: headline, detail: detail, lineNumber: lineNumber)
        return HTCondorJobEvent(
            code: code, job: job, time: time, kind: kind, resources: resourceTable(body), detail: detail
        )
    }

    private static func kind(code: Int, headline: String, detail: [String], lineNumber: Int) throws -> HTCondorJobEvent.Kind {
        switch code {
        case 1:
            let slot = detail.first { $0.hasPrefix("SlotName:") }
                .map { String($0.dropFirst("SlotName:".count)).trimmingCharacters(in: .whitespaces) }
            return .executing(host: hostName(headline), slotName: slot)
        case 4:
            let reason = detail.first { $0.hasPrefix("Reason:") }
                .map { String($0.dropFirst("Reason:".count)).trimmingCharacters(in: .whitespaces) }
            return .evicted(reason: reason)
        case 5:
            for line in detail {
                if let value = captures(normalTermination, in: line)?[1].flatMap({ Int($0) }) {
                    return .terminated(.exited(returnValue: value))
                }
                if let signal = captures(abnormalTermination, in: line)?[1].flatMap({ Int($0) }) {
                    return .terminated(.signaled(signal: signal))
                }
            }
            throw HTCondorJobEventLogError.malformedEvent(
                line: lineNumber, reason: "begins a 005 event that names no return value and no signal."
            )
        case 6:
            let size = headline.split(separator: ":").last.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            var memory: Int64?
            var resident: Int64?
            for line in detail {
                guard let groups = captures(sizeLine, in: line), let value = groups[1].flatMap({ Int64($0) }) else { continue }
                if groups[2] == "MemoryUsage" { memory = value } else { resident = value }
            }
            return .imageSizeUpdated(imageSizeKB: size ?? 0, memoryUsageMB: memory, residentSetSizeKB: resident)
        case 9:
            return .aborted(reason: detail.first)
        case 12:
            let reason = detail.first { captures(holdCode, in: $0) == nil } ?? ""
            let codes = detail.lazy.compactMap { captures(holdCode, in: $0) }.first
            return .held(
                reason: reason,
                code: codes?[1].flatMap { Int($0) },
                subcode: codes?[2].flatMap { Int($0) }
            )
        case 13:
            return .released(reason: detail.first)
        default:
            return .other
        }
    }

    /// The alias in a sinful address `<ip:port?addrs=...&alias=host&...>`, else the address, else the text after the
    /// headline's colon.
    static func hostName(_ headline: String) -> String {
        guard let open = headline.firstIndex(of: "<"), let close = headline[open...].firstIndex(of: ">") else {
            return headline.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let address = headline[headline.index(after: open)..<close]
        let parts = address.split(separator: "?", maxSplits: 1)
        if parts.count == 2 {
            for parameter in parts[1].split(separator: "&") where parameter.hasPrefix("alias=") {
                return String(parameter.dropFirst("alias=".count))
            }
        }
        return parts.first.map(String.init) ?? String(address)
    }

    /// The `Partitionable Resources` table: a header line naming the columns after its colon, then one line a resource.
    /// HTCondor right-aligns each value under its column's name, and leaves a column empty when it has no value.
    static func resourceTable(_ body: [String]) -> [HTCondorResourceUse] {
        guard let headerIndex = body.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Partitionable Resources")
        }) else { return [] }
        let header = Array(body[headerIndex])
        guard let colon = header.firstIndex(of: ":") else { return [] }
        let columns = words(header, after: colon)
        guard !columns.isEmpty else { return [] }
        var rows: [HTCondorResourceUse] = []
        for line in body[(headerIndex + 1)...] {
            let characters = Array(line)
            guard let rowColon = characters.firstIndex(of: ":") else { break }
            let label = String(characters[..<rowColon]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { break }
            let tokens = words(characters, after: rowColon)
            var values: [String: Double] = [:]
            if tokens.count == columns.count {
                for (token, column) in zip(tokens, columns) { values[column.text] = Double(token.text) }
            } else {
                // A short row: each value sits in the first column whose name ends at or after the value's end.
                for token in tokens {
                    let column = columns.first { $0.end >= token.end } ?? columns[columns.count - 1]
                    values[column.text] = Double(token.text)
                }
            }
            let (name, unit) = nameAndUnit(label)
            rows.append(HTCondorResourceUse(
                name: name, unit: unit, usage: values["Usage"], request: values["Request"], allocated: values["Allocated"]
            ))
        }
        return rows
    }

    private static func nameAndUnit(_ label: String) -> (String, String?) {
        guard let open = label.firstIndex(of: "("), label.hasSuffix(")") else { return (label, nil) }
        let name = label[..<open].trimmingCharacters(in: .whitespaces)
        let unit = label[label.index(after: open)..<label.index(before: label.endIndex)]
        return (name, String(unit))
    }

    /// The words after `start`, each with the offset one past its last character, counted from `start`.
    private static func words(_ characters: [Character], after start: Int) -> [(text: String, end: Int)] {
        var words: [(text: String, end: Int)] = []
        var current = ""
        for offset in (start + 1)..<(characters.count + 1) {
            let character: Character = offset < characters.count ? characters[offset] : " "
            if character == " " || character == "\t" {
                if !current.isEmpty { words.append((current, offset - start)) }
                current = ""
            } else {
                current.append(character)
            }
        }
        return words
    }

    private static func date(_ groups: [String?]) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        let parts = (5...10).map { Int(groups[$0] ?? "") }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5]
        )
        guard components.isValidDate(in: calendar), var date = calendar.date(from: components) else { return nil }
        if let fraction = groups[11].flatMap({ Double("0" + $0) }) { date += fraction }
        if let zone = groups[12], zone != "Z" {
            let digits = zone.dropFirst().filter(\.isNumber)
            let hours = Int(digits.prefix(2)) ?? 0
            let minutes = Int(digits.suffix(2)) ?? 0
            let offset = TimeInterval((hours * 60 + minutes) * 60)
            date -= zone.hasPrefix("-") ? -offset : offset
        }
        return date
    }

    /// The capture groups of the pattern's first match in `text`, group 0 the whole match, or nil when it does not match.
    private static func captures(_ expression: NSRegularExpression, in text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

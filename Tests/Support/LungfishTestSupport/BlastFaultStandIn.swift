// BlastFaultStandIn.swift - A loopback stand-in of NCBI's BLAST CGI with faults on demand
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import Synchronization

/// Which kind of contact a request to ``BlastFaultStandIn`` is.
public enum BlastFaultContact: Sendable, Equatable {
    case put
    case status
    case result
}

/// One request as ``BlastFaultStandIn`` read it, with the time on the stand-in's clock.
public struct BlastFaultArrival: Sendable, Equatable {
    public let contact: BlastFaultContact
    public let rid: String?
    public let at: Date
}

/// A loopback stand-in of NCBI's BLAST CGI that runs a ``BlastFaultScript`` for each Put, over ``LoopbackHTTPStandIn``.
///
/// Nothing in a test counts on how fast NCBI answers, so every path a search can take runs here, each fault on demand
/// (ARCH-BLAST-RESILIENCE section 7). A Put past the end of the scripts is ready at once. RIDs are `FAULT1`, `FAULT2`
/// and so on, in the order the Puts are accepted. Times count on the stand-in's own clock. Give it the same time scale
/// as a child, or the `now` of a hand clock for a test in process. Call ``stop()`` when the test ends.
public final class BlastFaultStandIn: Sendable {
    private let core: Core
    private let server: LoopbackHTTPStandIn

    /// Starts a stand-in that runs `scripts`, one for each accepted Put in order.
    ///
    /// - Parameters:
    ///   - scripts: What each accepted Put does.
    ///   - timeScale: How many times faster than the wall clock the stand-in's clock runs.
    ///   - now: Takes the place of the stand-in's clock, for a test that moves time by hand.
    public static func start(
        scripts: [BlastFaultScript] = [],
        timeScale: Double = 1,
        now: (@Sendable () -> Date)? = nil
    ) throws -> BlastFaultStandIn {
        let started = Date()
        let core = Core(scripts: scripts, now: now ?? {
            started.addingTimeInterval(Date().timeIntervalSince(started) * timeScale)
        })
        return BlastFaultStandIn(core: core, server: try LoopbackHTTPStandIn.start { core.answer($0) })
    }

    private init(core: Core, server: LoopbackHTTPStandIn) {
        self.core = core
        self.server = server
    }

    /// The RID the Put at this one-based place in the order of acceptance gets.
    public static func rid(ofPut ordinal: Int) -> String {
        "FAULT\(ordinal)"
    }

    /// `http://127.0.0.1:<port>`, the value of `LUNGFISH_BLAST_STAND_IN_ORIGIN`.
    public var baseURL: URL {
        server.baseURL
    }

    /// Every request read so far, in the order the stand-in read them, for a test that compares bytes.
    public var requests: [LoopbackHTTPRequest] {
        server.requests
    }

    /// Every contact on the BLAST CGI so far, with the time each came on the stand-in's clock.
    public var arrivals: [BlastFaultArrival] {
        core.arrivals
    }

    /// Lets a held search read READY from its next check on. A test can call it before the Put.
    public func release(rid: String) {
        core.release(rid: rid)
    }

    /// Returns as soon as `count` requests of `contact` have arrived, any contact when nil, and returns false when
    /// `deadline` passes first. It is resumed by the request itself and polls nothing, and the deadline is only a
    /// safety that no test should reach. It returns when the request is read and before it is answered.
    @discardableResult
    public func waitForRequest(
        count: Int,
        of contact: BlastFaultContact? = nil,
        deadline: Duration = WaitBudget.lookup.duration
    ) async -> Bool {
        await core.waitForRequest(count: count, of: contact, deadline: deadline)
    }

    /// Stops the server and ends every wait as a miss.
    public func stop() {
        core.endEveryWait()
        server.stop()
    }
}

// MARK: - The script runner

extension BlastFaultStandIn {
    private struct Waiter {
        let id: UUID
        let count: Int
        let contact: BlastFaultContact?
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// One accepted Put and what is left of its script.
    private struct Search {
        var script: BlastFaultScript
        let acceptedAt: Date
    }

    private struct State {
        var pendingPutFaults: [BlastFaultScript.PutFault]?
        var accepted = 0
        var searches: [String: Search] = [:]
        var released: Set<String> = []
        var arrivals: [BlastFaultArrival] = []
        var waiters: [Waiter] = []
        var stopped = false
    }

    private final class Core: Sendable {
        private let scripts: [BlastFaultScript]
        private let now: @Sendable () -> Date
        private let state = Mutex(State())

        init(scripts: [BlastFaultScript], now: @escaping @Sendable () -> Date) {
            self.scripts = scripts
            self.now = now
        }

        var arrivals: [BlastFaultArrival] {
            state.withLock { $0.arrivals }
        }

        func release(rid: String) {
            state.withLock { _ = $0.released.insert(rid) }
        }

        func answer(_ request: LoopbackHTTPRequest) -> LoopbackHTTPResponse {
            guard request.path == "/blast/Blast.cgi" else { return .notFound }
            let rid = request.queryItems.first { $0.name == "RID" }?.value
            let contact: BlastFaultContact
            if request.method == "POST" {
                contact = .put
            } else if request.queryItems.contains(URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo")) {
                contact = .status
            } else {
                contact = .result
            }

            let at = now()
            let (response, reached) = state.withLock { state -> (LoopbackHTTPResponse, [Waiter]) in
                let response: LoopbackHTTPResponse
                var answeredRID = rid
                switch contact {
                case .put: (response, answeredRID) = Self.answerPut(&state, scripts: scripts, at: at)
                case .status: response = Self.answerStatus(&state, rid: rid, at: at)
                case .result: response = Self.answerResult(&state, rid: rid)
                }
                state.arrivals.append(BlastFaultArrival(contact: contact, rid: answeredRID, at: at))
                let reached = state.waiters.filter { Self.isMet($0, in: state.arrivals) }
                state.waiters.removeAll { Self.isMet($0, in: state.arrivals) }
                return (response, reached)
            }
            for waiter in reached { waiter.continuation.resume(returning: true) }
            return response
        }

        func waitForRequest(count: Int, of contact: BlastFaultContact?, deadline: Duration) async -> Bool {
            let id = UUID()
            return await withCheckedContinuation { continuation in
                let waiter = Waiter(id: id, count: count, contact: contact, continuation: continuation)
                let endsNow = state.withLock { state -> Bool? in
                    if Self.isMet(waiter, in: state.arrivals) { return true }
                    if state.stopped { return false }
                    state.waiters.append(waiter)
                    return nil
                }
                if let endsNow {
                    continuation.resume(returning: endsNow)
                    return
                }
                let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) * 1e-18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.endWait(id: id) }
            }
        }

        func endEveryWait() {
            let waiters = state.withLock { state -> [Waiter] in
                state.stopped = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.continuation.resume(returning: false) }
        }

        private func endWait(id: UUID) {
            let missed = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            missed?.continuation.resume(returning: false)
        }

        private static func isMet(_ waiter: Waiter, in arrivals: [BlastFaultArrival]) -> Bool {
            let seen = waiter.contact.map { contact in arrivals.count { $0.contact == contact } } ?? arrivals.count
            return seen >= waiter.count
        }

        // MARK: Answers

        private static func answerPut(
            _ state: inout State,
            scripts: [BlastFaultScript],
            at: Date
        ) -> (LoopbackHTTPResponse, String?) {
            let script = state.accepted < scripts.count ? scripts[state.accepted] : BlastFaultScript()
            var faults = state.pendingPutFaults ?? script.put
            if !faults.isEmpty {
                let fault = faults.removeFirst()
                state.pendingPutFaults = faults
                switch fault {
                case .http(let status): return (page("Service unavailable", status: status), nil)
                case .noRID(let words): return (page(words), nil)
                case .droppedAfterSending: return (.droppedConnection, nil)
                }
            }
            state.pendingPutFaults = nil
            state.accepted += 1
            let rid = BlastFaultStandIn.rid(ofPut: state.accepted)
            state.searches[rid] = Search(script: script, acceptedAt: at)
            return (page(block("RID = \(rid)\n\tRTOE = \(script.rtoe)")), rid)
        }

        private static func answerStatus(_ state: inout State, rid: String?, at: Date) -> LoopbackHTTPResponse {
            guard let rid, var search = state.searches[rid] else { return page(block("Status=UNKNOWN")) }
            if !search.script.status.isEmpty {
                let fault = search.script.status.removeFirst()
                state.searches[rid] = search
                switch fault {
                case .http(let status): return page("Service unavailable", status: status)
                case .noStatusLine: return page("<html><body>Please wait</body></html>")
                case .emptyPage: return page("")
                case .unknown: return page(block("Status=UNKNOWN"))
                case .dropped: return .droppedConnection
                }
            }
            let elapsed = at.timeIntervalSince(search.acceptedAt)
            let isReleased = state.released.contains(rid)
            switch search.script.search {
            case .readyAtOnce: return ready(search.script)
            case .ready(let after): return elapsed >= after || isReleased ? ready(search.script) : waiting
            case .held: return isReleased ? ready(search.script) : waiting
            case .unknown(let after): return elapsed >= after ? page(block("Status=UNKNOWN")) : waiting
            case .failed(let words): return page(block("Status=FAILED") + "<p>\(words)</p>")
            }
        }

        private static func answerResult(_ state: inout State, rid: String?) -> LoopbackHTTPResponse {
            guard let rid, var search = state.searches[rid] else { return page("<html>RID not found</html>") }
            guard !search.script.result.isEmpty else {
                return LoopbackHTTPResponse(contentType: "application/json", body: search.script.body)
            }
            let fault = search.script.result.removeFirst()
            state.searches[rid] = search
            switch fault {
            case .http(let status): return page("Service unavailable", status: status)
            case .html: return page("<html><body>Results are not available</body></html>")
            case .empty: return page("")
            case .damagedZip: return LoopbackHTTPResponse(contentType: "application/zip", body: BlastFaultScript.damagedZip)
            case .dropped: return .droppedConnection
            }
        }

        // MARK: Pages, in the form NCBI writes them

        private static var waiting: LoopbackHTTPResponse {
            page(block("Status=WAITING"))
        }

        private static func ready(_ script: BlastFaultScript) -> LoopbackHTTPResponse {
            let hits = script.thereAreHits.map { block("ThereAreHits=\($0 ? "yes" : "no")") } ?? ""
            return page(block("Status=READY") + hits)
        }

        private static func block(_ lines: String) -> String {
            "<!--QBlastInfoBegin\n\t\(lines)\nQBlastInfoEnd\n-->\n"
        }

        private static func page(_ text: String, status: Int = 200) -> LoopbackHTTPResponse {
            LoopbackHTTPResponse(status: status, contentType: "text/html; charset=UTF-8", body: Data(text.utf8))
        }
    }
}

// LoopbackHTTPStandIn.swift - A loopback HTTP stand-in server for download tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Dispatch
import Foundation
import Synchronization

/// One request the stand-in read, as the client sent it.
public struct LoopbackHTTPRequest: Sendable, Equatable {
    /// The request method, such as `GET` or `HEAD`.
    public let method: String
    /// The request target, the path with its query, such as `/efetch.fcgi?db=nuccore`.
    public let target: String
    /// The header lines in the order the client sent them, without their line ends.
    public let headerLines: [String]
    /// The request body, empty for `GET` and `HEAD`.
    public let body: Data

    public init(method: String, target: String, headerLines: [String], body: Data) {
        self.method = method
        self.target = target
        self.headerLines = headerLines
        self.body = body
    }

    /// The target without its query.
    public var path: String {
        String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// The query items of the target, decoded and in order.
    public var queryItems: [URLQueryItem] {
        URLComponents(string: "http://stand-in\(target)")?.queryItems ?? []
    }
}

/// The answer the stand-in sends for one request.
public struct LoopbackHTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int = 200, contentType: String = "application/octet-stream", body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    /// A UTF-8 text answer.
    public static func text(_ text: String, status: Int = 200) -> LoopbackHTTPResponse {
        LoopbackHTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    /// The answer for a target the stand-in does not hold.
    public static let notFound = LoopbackHTTPResponse(
        status: 404, contentType: "text/plain; charset=utf-8", body: Data("Not Found\n".utf8))
}

/// A socket call that failed while the stand-in started.
public struct LoopbackHTTPStandInError: Error, CustomStringConvertible, Sendable {
    public let call: String
    public let code: Int32

    public var description: String {
        "\(call) failed: \(String(cString: strerror(code)))"
    }
}

/// A loopback HTTP/1.1 server on an ephemeral port that answers recorded responses.
///
/// Decision G5 of Phase 2.10 has stand-in servers answer both parity sides of a download, the
/// app in process and `lungfish-cli` in a child process, so both read the same bytes. The
/// stand-in binds 127.0.0.1 only on a port the system picks, closes each connection after one
/// answer and keeps every request it reads, so a test can compare request bytes. It never logs,
/// so a key a client sends reaches no log. Call `stop()` when the test ends.
public final class LoopbackHTTPStandIn: Sendable {
    /// `http://127.0.0.1:<port>`, with no trailing slash.
    public let baseURL: URL
    /// The port the system picked.
    public let port: UInt16

    private let listenDescriptor: Int32
    private let responder: @Sendable (LoopbackHTTPRequest) -> LoopbackHTTPResponse
    private let state = Mutex(State())
    private let acceptLoopEnded = DispatchSemaphore(value: 0)

    private struct State {
        var requests: [LoopbackHTTPRequest] = []
        var stopped = false
    }

    /// Starts a stand-in that answers each request with `responder`.
    public static func start(
        responder: @escaping @Sendable (LoopbackHTTPRequest) -> LoopbackHTTPResponse
    ) throws -> LoopbackHTTPStandIn {
        let (descriptor, port) = try bindLoopbackListener()
        let server = LoopbackHTTPStandIn(descriptor: descriptor, port: port, responder: responder)
        let thread = Thread { server.acceptLoop() }
        thread.name = "LoopbackHTTPStandIn \(port)"
        thread.start()
        return server
    }

    /// Starts a stand-in that answers each path in `routes` and gives 404 for any other path.
    public static func start(routes: [String: LoopbackHTTPResponse]) throws -> LoopbackHTTPStandIn {
        try start { request in routes[request.path] ?? .notFound }
    }

    private init(
        descriptor: Int32,
        port: UInt16,
        responder: @escaping @Sendable (LoopbackHTTPRequest) -> LoopbackHTTPResponse
    ) {
        self.listenDescriptor = descriptor
        self.port = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.responder = responder
    }

    /// The URL of `path` on the stand-in. `path` starts with a slash.
    public func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path)!
    }

    /// Every request read so far, in the order the stand-in read them.
    public var requests: [LoopbackHTTPRequest] {
        state.withLock { $0.requests }
    }

    /// Stops accepting connections and closes the listening socket. Waits at most 5 seconds.
    public func stop() {
        let wasRunning = state.withLock { state -> Bool in
            defer { state.stopped = true }
            return !state.stopped
        }
        guard wasRunning else { return }
        _ = acceptLoopEnded.wait(timeout: .now() + 5)
    }

    // MARK: - Socket work

    private static func bindLoopbackListener() throws -> (Int32, UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoopbackHTTPStandInError(call: "socket", code: errno) }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw closing(descriptor, call: "bind") }
        guard listen(descriptor, 64) == 0 else { throw closing(descriptor, call: "listen") }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard gotName == 0 else { throw closing(descriptor, call: "getsockname") }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            throw closing(descriptor, call: "fcntl")
        }
        return (descriptor, UInt16(bigEndian: named.sin_port))
    }

    private static func closing(_ descriptor: Int32, call: String) -> LoopbackHTTPStandInError {
        let error = LoopbackHTTPStandInError(call: call, code: errno)
        close(descriptor)
        return error
    }

    private func acceptLoop() {
        var listening = pollfd(fd: listenDescriptor, events: Int16(POLLIN), revents: 0)
        while !state.withLock({ $0.stopped }) {
            guard poll(&listening, 1, 100) > 0 else { continue }
            let client = accept(listenDescriptor, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
        }
        close(listenDescriptor)
        acceptLoopEnded.signal()
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let request = Self.readRequest(from: client) else { return }
        state.withLock { $0.requests.append(request) }
        let response = responder(request)
        var head = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var bytes = Data(head.utf8)
        if request.method != "HEAD" { bytes.append(response.body) }
        Self.writeAll(bytes, to: client)
    }

    private static func readRequest(from client: Int32) -> LoopbackHTTPRequest? {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let count = read(client, &chunk, chunk.count)
            guard count > 0, received.count < 1 << 20 else { return nil }
            received.append(contentsOf: chunk[0..<count])
            headEnd = received.range(of: separator)
        }
        guard let headEnd, let head = String(data: received[..<headEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let declaredLength = lines.lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        var body = Data(received[headEnd.upperBound...])
        while body.count < declaredLength {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { break }
            body.append(contentsOf: chunk[0..<count])
        }
        return LoopbackHTTPRequest(
            method: String(requestLine[0]), target: String(requestLine[1]),
            headerLines: lines, body: Data(body.prefix(declaredLength)))
    }

    private static func writeAll(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(client, pointer, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        default: "Status \(status)"
        }
    }
}

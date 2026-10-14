// SRAArchivesStandIn.swift - A loopback server that answers as SRAScriptedArchives scripts ENA and NCBI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

/// One loopback server for the archives an SRA run download asks (Phase 2.10 lane A45 M3c, decisions
/// G1 and G5). The window's task runs in the test process and `lungfish-cli fetch sra download` runs in a
/// child, and both reach this server through the stand-in origin variables of `ENAServiceEndpoints` and
/// `NCBIServiceEndpoints`, so the two sides of a parity case get the very same answers.
///
/// It answers what an ``SRAScriptedArchives`` is scripted to answer, so a test scripts ENA's portal and
/// mirror and NCBI's run info once, as the unit tests of the download do. ENA's portal is
/// `/ena/portal/api/filereport`, its mirror is `/vol1/...` and NCBI's run info is `/entrez/eutils/efetch.fcgi`.
/// The scripted archives keep every request they answered, in their `requestLog`.
public enum SRAArchivesStandIn {
    /// Starts the server. The caller stops it.
    public static func start(serving archives: SRAScriptedArchives) throws -> LoopbackHTTPStandIn {
        try LoopbackHTTPStandIn.start { request in
            let url = URL(string: "http://127.0.0.1" + request.target) ?? URL(string: "http://127.0.0.1/")!
            let answer = OSAllocatedUnfairLock(initialState: LoopbackHTTPResponse.notFound)
            let done = DispatchSemaphore(value: 0)
            // The server's thread waits for the scripted archives, which answer on the concurrency pool.
            Task.detached {
                let response = await Self.answer(archives, path: request.path, url: url)
                answer.withLock { $0 = response }
                done.signal()
            }
            done.wait()
            return answer.withLock { $0 }
        }
    }

    private static func answer(_ archives: SRAScriptedArchives, path: String, url: URL) async -> LoopbackHTTPResponse {
        if path.hasPrefix("/vol1/") {
            guard let data = try? await archives.mirrorFile(url) else { return .notFound }
            return LoopbackHTTPResponse(status: 200, contentType: "application/gzip", body: data)
        }
        do {
            let (data, response) = try await archives.data(for: URLRequest(url: url))
            let contentType = path.contains("efetch") ? "text/csv" : "application/json"
            return LoopbackHTTPResponse(
                status: (response as? HTTPURLResponse)?.statusCode ?? 200, contentType: contentType, body: data)
        } catch {
            return LoopbackHTTPResponse(status: 500, contentType: "text/plain", body: Data("scripted failure".utf8))
        }
    }
}

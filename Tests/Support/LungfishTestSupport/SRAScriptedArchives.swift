// SRAScriptedArchives.swift - ENA's portal and mirror and NCBI's run info, scripted for SRA download tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore

/// ENA's portal and FASTQ mirror and NCBI's SRA run info, answering as a test
/// scripts them, so an SRA download test reaches no network.
///
/// It is the `HTTPClient` that `SRAService` and `ENAService` take, which is
/// how `lungfish-cli fetch sra download` reaches the archives, and its
/// `mirrorFile(_:)` serves the same bytes and failures the way the window's
/// streaming download reports them. So the window and the CLI can be driven
/// by the very same answers. It keeps every request it answered.
public final class SRAScriptedArchives: HTTPClient, @unchecked Sendable {
    /// How the mirror fails one file.
    public enum MirrorFailure: Sendable {
        /// The mirror answers this HTTP status.
        case status(Int)
        /// The connection drops partway.
        case connectionLost
        /// The transfer is cancelled, as a cancelled task cancels it.
        case cancelled
    }

    /// What ENA's portal lists for one run.
    public struct ENARun: Sendable {
        public var layout: String?
        public var platform: String?
        /// The files ENA lists, in its order, with the bytes the mirror serves.
        public var files: [(name: String, data: Data)]
        /// The MD5s ENA lists, or nil to list each file's true MD5. An entry
        /// overrides the file of the same position.
        public var listedMD5s: [String]?
        /// The run accession ENA answers with, when it is not the one asked for.
        public var answeredAccession: String?

        public init(
            layout: String? = "PAIRED",
            platform: String? = "ILLUMINA",
            files: [(name: String, data: Data)],
            listedMD5s: [String]? = nil,
            answeredAccession: String? = nil
        ) {
            self.layout = layout
            self.platform = platform
            self.files = files
            self.listedMD5s = listedMD5s
            self.answeredAccession = answeredAccession
        }
    }

    /// How NCBI's run info service fails every request.
    public enum NCBIFailure: Sendable {
        /// NCBI answers HTTP 500, as in an outage.
        case down
        /// The request is cancelled, as cancelling the task that waits on
        /// it cancels it. The task is cancelled too.
        case cancelled
    }

    private let lock = NSLock()
    private var enaRuns: [String: ENARun] = [:]
    private var enaIsDown = false
    private var ncbiFailure: NCBIFailure?
    private var ncbiLayouts: [String: String] = [:]
    private var mirrorFailures: [String: MirrorFailure] = [:]
    private var servedFiles: [String: Data] = [:]
    private var requests: [String] = []

    public init() {}

    // MARK: - Scripting

    /// ENA's portal answers every lookup with HTTP 500 and an error page.
    public func takeENADown() {
        lock.withLock { enaIsDown = true }
    }

    /// ENA's portal lists `run` for `accession`, and its mirror serves the files.
    public func listOnENA(_ accession: String, _ run: ENARun) {
        lock.withLock {
            enaRuns[accession] = run
            for file in run.files {
                servedFiles[file.name] = file.data
            }
        }
    }

    /// The mirror fails `filename` as `failure`.
    public func failOnMirror(_ filename: String, _ failure: MirrorFailure) {
        lock.withLock { mirrorFailures[filename] = failure }
    }

    /// The mirror serves `data` for `filename` in place of the listed bytes.
    public func serveOnMirror(_ filename: String, _ data: Data) {
        lock.withLock { servedFiles[filename] = data }
    }

    /// NCBI's run info lists `accession` with `layout`, such as "PAIRED".
    public func listOnNCBI(_ accession: String, layout: String) {
        lock.withLock { ncbiLayouts[accession] = layout }
    }

    /// NCBI's run info service fails every request as `failure`.
    public func failOnNCBI(_ failure: NCBIFailure) {
        lock.withLock { ncbiFailure = failure }
    }

    /// Every request answered, as "ena <accession>", "ncbi <ids>" or
    /// "mirror <file name>", in order.
    public var requestLog: [String] {
        lock.withLock { requests }
    }

    /// The mirror requests answered, by file name.
    public var mirrorRequests: [String] {
        requestLog.filter { $0.hasPrefix("mirror ") }.map { String($0.dropFirst("mirror ".count)) }
    }

    /// The NCBI run info requests answered.
    public var ncbiRequests: [String] {
        requestLog.filter { $0.hasPrefix("ncbi ") }
    }

    /// The lower-case hexadecimal MD5 of `data`.
    public static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTPClient

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String {
            components?.queryItems?.first { $0.name == name }?.value ?? ""
        }
        if url.absoluteString.contains("portal/api/filereport") {
            let accession = query("accession")
            let (down, run) = lock.withLock { () -> (Bool, ENARun?) in
                requests.append("ena \(accession)")
                return (enaIsDown, enaRuns[accession])
            }
            if down {
                return (Data("<html><body>Internal Server Error</body></html>".utf8), Self.response(url, 500))
            }
            guard let run else {
                return (Data("[]".utf8), Self.response(url, 200))
            }
            return (try Self.portalJSON(accession: accession, run: run), Self.response(url, 200))
        }
        if url.absoluteString.contains("efetch.fcgi") {
            let ids = query("id")
            let (layouts, failure) = lock.withLock { () -> ([String: String], NCBIFailure?) in
                requests.append("ncbi \(ids)")
                return (ncbiLayouts, ncbiFailure)
            }
            switch failure {
            case .down?:
                return (Data("<html><body>Service Unavailable</body></html>".utf8), Self.response(url, 500))
            case .cancelled?:
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            case nil:
                break
            }
            let rows = ids.split(separator: ",").compactMap { id -> String? in
                layouts[String(id)].map { Self.runInfoRow(accession: String(id), layout: $0) }
            }
            return (Data(([Self.runInfoHeader] + rows).joined(separator: "\n").utf8), Self.response(url, 200))
        }
        throw URLError(.cannotFindHost)
    }

    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let data: Data
        do {
            data = try await mirrorBytes(url)
        } catch let status as MirrorStatus {
            let temporaryURL = try Self.temporaryFile(Data("<html>error</html>".utf8))
            return (temporaryURL, Self.response(url, status.code))
        }
        return (try Self.temporaryFile(data), Self.response(url, 200))
    }

    /// One file from the mirror, as the window's `mirrorFile` closure gets it.
    /// An HTTP error status throws `DatabaseServiceError.serverError`, as the
    /// window's streaming download reports it.
    public func mirrorFile(_ url: URL) async throws -> Data {
        do {
            return try await mirrorBytes(url)
        } catch let status as MirrorStatus {
            throw DatabaseServiceError.serverError(message: "HTTP \(status.code) downloading \(url.lastPathComponent)")
        }
    }

    // MARK: - Private

    private struct MirrorStatus: Error {
        let code: Int
    }

    private func mirrorBytes(_ url: URL) async throws -> Data {
        let name = url.lastPathComponent
        let (failure, data) = lock.withLock { () -> (MirrorFailure?, Data?) in
            requests.append("mirror \(name)")
            return (mirrorFailures[name], servedFiles[name])
        }
        switch failure {
        case .status(let code)?:
            throw MirrorStatus(code: code)
        case .connectionLost?:
            throw URLError(.networkConnectionLost)
        case .cancelled?:
            throw CancellationError()
        case nil:
            guard let data else { throw MirrorStatus(code: 404) }
            return data
        }
    }

    private static func portalJSON(accession: String, run: ENARun) throws -> Data {
        let folder = "ftp.sra.ebi.ac.uk/vol1/fastq/\(accession.prefix(6))/\(accession)"
        var record: [String: Any] = [
            "run_accession": run.answeredAccession ?? accession,
            "fastq_ftp": run.files.map { "\(folder)/\($0.name)" }.joined(separator: ";"),
            "fastq_bytes": run.files.map { String($0.data.count) }.joined(separator: ";"),
            "fastq_md5": (run.listedMD5s ?? run.files.map { md5($0.data) }).joined(separator: ";"),
        ]
        if let layout = run.layout { record["library_layout"] = layout }
        if let platform = run.platform { record["instrument_platform"] = platform }
        return try JSONSerialization.data(withJSONObject: [record])
    }

    private static let runInfoHeader = "Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName,SampleName"

    private static func runInfoRow(accession: String, layout: String) -> String {
        var fields = Array(repeating: "", count: 30)
        fields[0] = accession
        fields[12] = "WGS"
        fields[14] = "GENOMIC"
        fields[15] = layout
        fields[18] = "ILLUMINA"
        return fields.joined(separator: ",")
    }

    private static func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-scripted-archives-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

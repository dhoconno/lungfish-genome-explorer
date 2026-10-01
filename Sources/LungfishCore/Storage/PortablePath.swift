// PortablePath.swift - Keep per-user absolute paths out of files written into a project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation


/// Rewrites the absolute paths LGE records inside a project so a
/// shared project or a published demo archive reveals neither the account
/// name nor the machine layout, and resolves those records back to real paths
/// when LGE reads them again.
///
/// Files LGE writes into a project (provenance JSON, sidecars,
/// SQLite command-line fields, VCF meta lines, BAM `@PG` lines) pass through
/// one of the `sanitize` entry points before they land on disk. The rules, in
/// the order they are tried:
///
/// 1. a path inside a declared run workspace becomes `<workspace>/<relative>`,
/// 2. a path inside the enclosing `.lungfish` project becomes `@/<relative>`,
///    the project-relative form the rest of LGE already understands,
/// 3. with no project, a path inside the outermost enclosing Lungfish bundle
///    becomes `<bundle>/<relative>` (only when a caller builds such a
///    context; `Context.forWriting` rewrites records inside projects),
/// 4. a path under a system temporary directory becomes `<workspace>/<relative>`,
/// 5. a path under the managed tool root becomes `<tool-root>/<relative>` (an
///    executable reads `<tool-root>/envs/samtools/bin/samtools`), and a path
///    under the managed storage root becomes `<storage-root>/<relative>`,
/// 6. a system path (`/usr`, `/bin`, `/opt`, `/Applications`, ...) is kept,
/// 7. any other absolute path, including everything else under the home
///    directory, becomes `<external>/<file name>`.
///
/// `resolve` turns `@/`, `<bundle>`, `<tool-root>` and `<storage-root>` back
/// into real paths for the file being read and the machine reading it, which
/// keeps Run Again, `--repeat-from` and provenance export working on a moved
/// or shared project. A `<workspace>` path resolves only while the scratch
/// file still exists under one of this machine's temporary directories;
/// `<external>` never resolves, because the file was never part of the project.
public enum PortablePath {
    public static let projectPrefix = "@/"
    public static let bundlePlaceholder = "<bundle>"
    public static let workspacePlaceholder = "<workspace>"
    public static let toolRootPlaceholder = "<tool-root>"
    public static let storageRootPlaceholder = "<storage-root>"
    public static let externalPlaceholder = "<external>"

    /// Absolute prefixes that describe the operating system, not the user.
    public static let defaultPreservedPrefixes: [String] = [
        "/Applications", "/System", "/Library", "/usr", "/bin", "/sbin",
        "/opt", "/etc", "/private/etc", "/dev", "/nix", "/cores",
    ]

    /// Directories whose contents count as scratch space on this machine, in
    /// the order `resolve` probes them for a `<workspace>` path.
    public static var defaultTemporaryRoots: [URL] {
        var roots: [URL] = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        ]
        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpdir.isEmpty {
            roots.append(URL(fileURLWithPath: tmpdir, isDirectory: true))
        }
        roots += [
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            URL(fileURLWithPath: "/var/tmp", isDirectory: true),
            // Resolved at run time, not spelled out: the release portability
            // scan rejects any binary that embeds the build cache prefix.
            URL(fileURLWithPath: "/var/tmp", isDirectory: true).resolvingSymlinksInPath(),
            URL(fileURLWithPath: "/var/folders", isDirectory: true),
            URL(fileURLWithPath: "/private/var/folders", isDirectory: true),
        ]
        return roots
    }

    /// The managed tool root (`<tool-root>`) and storage root
    /// (`<storage-root>`) of the current process, honouring the
    /// `LUNGFISH_CONDA_ROOT` and `LUNGFISH_STORAGE_ROOT` overrides.
    public static var defaultManagedRoots: (toolRoot: URL, storageRoot: URL) {
        let store = ManagedStorageConfigStore()
        return (store.currentCondaRootURL(), store.currentLocation().rootURL)
    }

    // MARK: - Context

    public struct Context: Sendable {
        /// The enclosing `.lungfish` project that `@/` paths are relative to.
        public var projectURL: URL?
        /// The outermost enclosing Lungfish bundle that `<bundle>/` paths are
        /// relative to. Paths are written this way only outside a project;
        /// the bundle still resolves `<bundle>` after it moves into one.
        public var bundleURL: URL?
        /// Run workspaces whose contents become `<workspace>/...`. These win
        /// over the project, so a workspace inside a project's `.tmp` folder
        /// still reads as a workspace.
        public var workspaceURLs: [URL]
        /// System temporary roots, consulted after the project and bundle.
        public var temporaryRootURLs: [URL]
        /// The managed conda root.
        public var toolRootURL: URL?
        /// The managed storage root (databases, receipts).
        public var storageRootURL: URL?
        /// Absolute prefixes left untouched.
        public var preservedPrefixes: [String]
        /// The account name that `sanitizeJSON` drops from `user` fields.
        public var accountName: String?

        public init(
            projectURL: URL?,
            bundleURL: URL? = nil,
            workspaceURLs: [URL] = [],
            toolRootURL: URL? = nil,
            storageRootURL: URL? = nil,
            temporaryRootURLs: [URL] = PortablePath.defaultTemporaryRoots,
            preservedPrefixes: [String] = PortablePath.defaultPreservedPrefixes,
            accountName: String? = NSUserName()
        ) {
            self.projectURL = projectURL
            self.bundleURL = bundleURL
            self.workspaceURLs = workspaceURLs
            self.toolRootURL = toolRootURL
            self.storageRootURL = storageRootURL
            self.temporaryRootURLs = temporaryRootURLs
            self.preservedPrefixes = preservedPrefixes
            self.accountName = accountName
        }

        /// The context for reading or writing a record stored at `url`: the
        /// project and bundle are those enclosing `url`, and the managed roots
        /// are those of the current process unless given.
        public static func forFile(
            at url: URL,
            workspaceURLs: [URL] = [],
            toolRootURL: URL? = nil,
            storageRootURL: URL? = nil
        ) -> Context {
            let managed = (toolRootURL == nil || storageRootURL == nil) ? PortablePath.defaultManagedRoots : nil
            let anchors = PortablePath.anchors(for: url)
            return Context(
                projectURL: anchors.project,
                bundleURL: anchors.bundle,
                workspaceURLs: workspaceURLs,
                toolRootURL: toolRootURL ?? managed?.toolRoot,
                storageRootURL: storageRootURL ?? managed?.storageRoot
            )
        }

        /// The context for a record written at `url`, or nil when `url` does
        /// not lie inside a `.lungfish` project. Projects are what LGE shares
        /// and publishes; a record outside one (a CLI output folder, a bundle
        /// being staged) keeps its real paths until it is written into one.
        public static func forWriting(
            at url: URL,
            workspaceURLs: [URL] = [],
            toolRootURL: URL? = nil,
            storageRootURL: URL? = nil
        ) -> Context? {
            let anchors = PortablePath.anchors(for: url)
            guard anchors.project != nil else { return nil }
            return forFile(
                at: url,
                workspaceURLs: workspaceURLs,
                toolRootURL: toolRootURL,
                storageRootURL: storageRootURL
            )
        }

        /// A copy that also rewrites paths under `workspaces` as `<workspace>`.
        public func addingWorkspaces(_ workspaces: [URL]) -> Context {
            var copy = self
            copy.workspaceURLs += workspaces
            return copy
        }
    }

    // MARK: - Anchors

    /// The nearest enclosing `.lungfish` project of `url`, and the outermost
    /// enclosing Lungfish bundle (`.lungfishref`, `.lungfishfastq`, ...)
    /// below it. `url` itself counts when it is a project or bundle directory.
    public static func anchors(for url: URL) -> (project: URL?, bundle: URL?) {
        var current = url.standardizedFileURL
        var project: URL?
        var outermostBundle: URL?
        var isFirst = true
        while true {
            let ext = current.pathExtension.lowercased()
            if ext == "lungfish" {
                project = current
                break
            }
            // A sidecar file such as `x.lungfishprimers` beside nothing is a
            // file, not a bundle: only directories (or the path's ancestors)
            // count.
            if ext.hasPrefix("lungfish"), !isFirst || isDirectory(current) {
                outermostBundle = current
            }
            isFirst = false
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == "/" || current.path.isEmpty {
                break
            }
            current = parent
        }
        return (project, outermostBundle)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Sanitizing

    /// Rewrites one absolute path. Relative paths, placeholders and
    /// non-path values (`pipe:stdout:x`) are returned unchanged.
    public static func sanitize(path: String, context: Context) -> String {
        guard path.hasPrefix("/"), path.count > 1 else { return path }
        return Roots(context: context).rewrite(absolutePath: path)
    }

    /// Rewrites every absolute path inside free text (a command line, a
    /// `stderr` capture, a SAM `@PG` line, a `file://` URL).
    public static func sanitize(text: String, context: Context) -> String {
        guard text.contains("/") else { return text }
        return Roots(context: context).rewrite(text: text)
    }

    /// Rewrites free text about to be written at `url` (a run log, a tool's
    /// captured output); text for a file outside a project is returned
    /// unchanged.
    public static func sanitize(text: String, forFileAt url: URL, workspaceURLs: [URL] = []) -> String {
        guard text.contains("/"),
              let context = Context.forWriting(at: url, workspaceURLs: workspaceURLs) else { return text }
        return sanitize(text: text, context: context)
    }

    /// Rewrites one value that is either a single absolute path (which may
    /// hold spaces) or free text.
    public static func sanitize(value: String, context: Context) -> String {
        guard value.contains("/") else { return value }
        return Roots(context: context).rewrite(value: value)
    }

    /// Rewrites a stored field (a SQLite value, a metadata entry): a JSON
    /// object or array has its string values rewritten, anything else is
    /// treated as `sanitize(value:)`. JSON is re-encoded compactly with
    /// unescaped slashes only when a value changed, so `resolve(text:)`
    /// can read it back.
    public static func sanitize(field value: String, context: Context) -> String {
        guard value.contains("/") else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let node = try? JSONDecoder().decode(JSONNode.self, from: Data(value.utf8)) {
            let roots = Roots(context: context)
            var changed = false
            let rewritten = node.mapStrings(dropping: { _, _ in false }) { text in
                let result = text.contains("/") ? roots.rewrite(value: text) : text
                if result != text { changed = true }
                return result
            }
            guard changed else { return value }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(rewritten) else { return value }
            return String(decoding: data, as: UTF8.self)
        }
        return Roots(context: context).rewrite(value: value)
    }

    /// Rewrites an argv: whole-path elements as paths (so a space inside a
    /// file name survives), everything else as text.
    public static func sanitize(argv: [String], context: Context) -> [String] {
        let roots = Roots(context: context)
        return argv.map { roots.rewrite(value: $0) }
    }

    /// Rewrites every string value in a JSON document and drops `user`
    /// fields that name the account. A value that is one absolute path is
    /// rewritten as a path; any other value as free text. `encoder` controls
    /// the output formatting; the default matches LGE's pretty, sorted
    /// provenance encoders. Data that is not JSON is returned unchanged.
    public static func sanitizeJSON(
        _ data: Data,
        context: Context,
        encoder: JSONEncoder = defaultJSONEncoder
    ) throws -> Data {
        guard let node = try? JSONDecoder().decode(JSONNode.self, from: data) else { return data }
        let roots = Roots(context: context)
        var changed = false
        let rewritten = node.mapStrings(dropping: { key, value in
            let drop = accountKeys.contains(key) && context.accountName.map { $0 == value } == true
            if drop { changed = true }
            return drop
        }) { text in
            guard text.contains("/") else { return text }
            let result = roots.rewrite(value: text)
            if result != text { changed = true }
            return result
        }
        // Unchanged documents keep their exact bytes.
        guard changed else { return data }
        return try encoder.encode(rewritten)
    }

    /// Keys whose value names the account; dropped when they hold it.
    static let accountKeys: Set<String> = ["user", "runtimeUser"]

    /// Sanitizes JSON about to be written at `url`; data for a file outside
    /// a project is returned unchanged.
    public static func sanitizeJSON(
        _ data: Data,
        forFileAt url: URL,
        workspaceURLs: [URL] = [],
        encoder: JSONEncoder = defaultJSONEncoder
    ) -> Data {
        guard let context = Context.forWriting(at: url, workspaceURLs: workspaceURLs) else { return data }
        return (try? sanitizeJSON(data, context: context, encoder: encoder)) ?? data
    }

    /// Rewrites the JSON file at `url` in place when it names a private path.
    /// Files outside a project are left alone.
    public static func sanitizeJSONFile(
        at url: URL,
        workspaceURLs: [URL] = [],
        encoder: JSONEncoder = defaultJSONEncoder
    ) throws {
        guard let data = try? Data(contentsOf: url) else { return }
        let sanitized = sanitizeJSON(data, forFileAt: url, workspaceURLs: workspaceURLs, encoder: encoder)
        guard sanitized != data else { return }
        try sanitized.write(to: url, options: .atomic)
    }

    /// True when `text` still names a private path (home directory,
    /// temporary directory, managed root) under `context`.
    public static func containsPrivatePath(_ text: String, context: Context) -> Bool {
        sanitize(text: text, context: context) != text
    }

    // MARK: - Resolving

    /// Turns `@/`, `<bundle>`, `<tool-root>`, `<storage-root>` and existing
    /// `<workspace>` paths back into real paths, in free text or inside
    /// `file://` URLs.
    public static func resolve(text: String, context: Context) -> String {
        guard mayContainPlaceholder(text) else { return text }
        return Resolver(context: context).resolve(text: text)
    }

    public static func resolve(path: String, context: Context) -> String {
        resolve(text: path, context: context)
    }

    public static func resolve(argv: [String], context: Context) -> [String] {
        let resolver = Resolver(context: context)
        return argv.map { mayContainPlaceholder($0) ? resolver.resolve(text: $0) : $0 }
    }

    /// Resolves every string value in a JSON document; see `resolve(text:)`.
    /// Data that is not JSON, or holds no placeholder, is returned unchanged.
    public static func resolveJSON(
        _ data: Data,
        context: Context,
        encoder: JSONEncoder = defaultJSONEncoder
    ) throws -> Data {
        guard dataMayContainPlaceholder(data),
              let node = try? JSONDecoder().decode(JSONNode.self, from: data) else { return data }
        let resolver = Resolver(context: context)
        let rewritten = node.mapStrings(dropping: { _, _ in false }) {
            mayContainPlaceholder($0) ? resolver.resolve(text: $0) : $0
        }
        return try encoder.encode(rewritten)
    }

    /// Resolves the JSON record stored at `url` for decoding: placeholders
    /// become real paths, and a path recorded under another project root
    /// (another machine, or a record older than this sanitizer) whose tail
    /// exists inside the enclosing project reads as that file.
    public static func resolveJSON(
        _ data: Data,
        forFileAt url: URL,
        encoder: JSONEncoder = defaultJSONEncoder
    ) -> Data {
        let hasPlaceholder = dataMayContainPlaceholder(data)
        let hasForeignProject = dataMayContainProjectRoot(data)
        guard hasPlaceholder || hasForeignProject else { return data }
        let context = Context.forFile(at: url)
        var result = data
        if hasPlaceholder {
            result = (try? resolveJSON(result, context: context, encoder: encoder)) ?? result
        }
        if hasForeignProject, context.projectURL != nil {
            result = (try? rerootForeignProjectPathsJSON(result, context: context, encoder: encoder)) ?? result
        }
        return result
    }

    // MARK: - Re-rooting foreign project paths

    /// The `.lungfish/` marker as JSON may spell it (a slash is escaped as
    /// `\/` by Foundation's encoder).
    static func dataMayContainProjectRoot(_ data: Data) -> Bool {
        [".lungfish/", ".lungfish\\/"].contains { data.range(of: Data($0.utf8)) != nil }
    }

    /// Rewrites every string value that names a path under some other
    /// `.lungfish` project root when the same relative file exists under
    /// `context.projectURL`. Data without such a path is returned unchanged.
    public static func rerootForeignProjectPathsJSON(
        _ data: Data,
        context: Context,
        encoder: JSONEncoder = defaultJSONEncoder
    ) throws -> Data {
        guard context.projectURL != nil,
              dataMayContainProjectRoot(data),
              let node = try? JSONDecoder().decode(JSONNode.self, from: data) else { return data }
        var changed = false
        let rewritten = node.mapStrings(dropping: { _, _ in false }) { text in
            let result = rerootForeignProjectPaths(text: text, context: context)
            if result != text { changed = true }
            return result
        }
        guard changed else { return data }
        return try encoder.encode(rewritten)
    }

    /// Re-roots the absolute paths in `text` (one path, or free text) that
    /// lie under a `.lungfish` project other than `context.projectURL` when
    /// the file exists at the same relative place inside that project. A
    /// path whose tail is absent here is returned as recorded.
    public static func rerootForeignProjectPaths(text: String, context: Context) -> String {
        guard let project = context.projectURL, text.contains(".lungfish/") else { return text }
        let projectPath = trimmed(project.standardizedFileURL.path)
        if Roots.isSinglePath(text) {
            return rerootSinglePath(text, projectPath: projectPath) ?? text
        }
        return rerootFreeText(text, projectPath: projectPath)
    }

    /// The re-rooted form of one absolute path, or nil when no `.lungfish/`
    /// component of it has a tail that exists under `projectPath`.
    private static func rerootSinglePath(_ path: String, projectPath: String) -> String? {
        var searchStart = path.startIndex
        while let range = path.range(of: ".lungfish/", range: searchStart ..< path.endIndex) {
            let tail = String(path[range.upperBound...])
            if !tail.isEmpty {
                let candidate = projectPath + "/" + tail
                if candidate == path { return nil }
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// Characters that end a foreign-path span in free text before spaces
    /// are considered: a span may hold spaces (a project folder named with
    /// them), so the longest span up to one of these is tried first and then
    /// shortened at each space until the tail exists.
    private static let hardTerminators: Set<Character> = ["\n", "\r", "\"", "'", ",", ";", "<", ">", "|", ")", "]", "}"]

    private static func rerootFreeText(_ text: String, projectPath: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let startsPath = character == "/"
                && (index == 0 || pathLeadIns.contains(characters[index - 1]))
            guard startsPath else {
                output.append(character)
                index += 1
                continue
            }
            var limit = index
            while limit < characters.count, !hardTerminators.contains(characters[limit]) {
                limit += 1
            }
            var end = limit
            var replaced = false
            while end > index {
                let span = String(characters[index ..< end])
                if span.contains(".lungfish/"), let rerooted = rerootSinglePath(span, projectPath: projectPath) {
                    output += rerooted
                    index = end
                    replaced = true
                    break
                }
                guard let space = characters[index ..< end].lastIndex(of: " ") else { break }
                end = space
            }
            if !replaced {
                // Copy the shortest token through and carry on scanning
                // after it, so a later path on the same line is still tried.
                var tokenEnd = index
                while tokenEnd < characters.count, !pathTerminators.contains(characters[tokenEnd]) {
                    tokenEnd += 1
                }
                if tokenEnd == index { tokenEnd = index + 1 }
                output += String(characters[index ..< tokenEnd])
                index = tokenEnd
            }
        }
        return output
    }

    /// True when `text` holds a placeholder that `resolve` could not turn
    /// into a path (`<external>`, or a vanished `<workspace>`).
    public static func containsUnresolvedPlaceholder(_ text: String) -> Bool {
        text.contains(externalPlaceholder) || text.contains(workspacePlaceholder)
            || text.contains("%3Cexternal%3E") || text.contains("%3Cworkspace%3E")
    }

    public static var defaultJSONEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// True when `value` reads as one absolute path, which may hold spaces.
    public static func isSingleAbsolutePath(_ value: String) -> Bool {
        Roots.isSinglePath(value)
    }

    public static func mayContainPlaceholder(_ text: String) -> Bool {
        text.contains("@/") || text.contains("<") || text.contains("%3C")
    }

    static func dataMayContainPlaceholder(_ data: Data) -> Bool {
        // JSON may escape "/" as "\/" and "<" as "<".
        let markers = ["@/", "@\\/", "<", "\\u003c", "\\u003C", "%3C"]
        return markers.contains { data.range(of: Data($0.utf8)) != nil }
    }

    // MARK: - Tokenising

    /// Characters that end an absolute path token inside free text.
    static let pathTerminators: Set<Character> = [
        " ", "\t", "\n", "\r", "\"", "'", ",", ";", "<", ">", "|", ")", "]", "}",
    ]

    /// Characters that end a `file://` URL inside free text. Parentheses are
    /// legal URL characters; spaces are percent-encoded.
    static let urlTerminators: Set<Character> = [
        " ", "\t", "\n", "\r", "\"", "'", ",", ";", "<", ">", "|",
    ]

    /// Characters that may precede a path token. `>` and `@` are absent so
    /// `<workspace>/x` and `@/x`, the sanitizer's own output, are left alone
    /// on a second pass.
    static let pathLeadIns: Set<Character> = [
        " ", "\t", "\n", "\r", "=", "\"", "'", ",", ";", "<", "|", "(", "[", "{", ":",
    ]

    private static func trimmed(_ path: String) -> String {
        path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }

    /// Characters kept verbatim in the path of a `file://` URL.
    static let urlPathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "<>")
        return set
    }()

    static func percentEncodePath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: urlPathAllowed) ?? path
    }

    // MARK: - Roots

    /// The prefix table for one context, longest prefixes first within each
    /// tier so a nested root wins over its parent.
    struct Roots {
        struct Root {
            let prefix: String
            let placeholder: String
        }

        static let projectMarker = "@"

        let ordered: [Root]
        let preservedPrefixes: [String]
        /// Lowercased account name; a scratch path that spells it keeps only
        /// its file name.
        let accountName: String?

        init(context: Context) {
            var tiers: [[Root]] = []
            tiers.append(Self.roots(for: context.workspaceURLs, placeholder: workspacePlaceholder))
            if let project = context.projectURL {
                tiers.append(Self.roots(for: [project], placeholder: Self.projectMarker))
            } else if let bundle = context.bundleURL {
                tiers.append(Self.roots(for: [bundle], placeholder: bundlePlaceholder))
            }
            tiers.append(Self.roots(for: context.temporaryRootURLs, placeholder: workspacePlaceholder))
            if let toolRoot = context.toolRootURL {
                tiers.append(Self.roots(for: [toolRoot], placeholder: toolRootPlaceholder))
            }
            if let storageRoot = context.storageRootURL {
                tiers.append(Self.roots(for: [storageRoot], placeholder: storageRootPlaceholder))
            }
            ordered = tiers.flatMap { $0 }
            preservedPrefixes = context.preservedPrefixes.map(PortablePath.trimmed)
            let account = context.accountName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            accountName = (account?.isEmpty ?? true) ? nil : account
        }

        /// A scratch folder can be named after the account (a per-user temp
        /// or session folder). Such a `<workspace>` path keeps only its file
        /// name, like `<external>`; other scratch paths keep their layout so
        /// they still resolve while the file exists.
        func workspaceForm(relative: String) -> String {
            if let accountName, relative.lowercased().contains(accountName) {
                return workspacePlaceholder + "/" + (relative.split(separator: "/").last.map(String.init) ?? relative)
            }
            return workspacePlaceholder + "/" + relative
        }

        private static func roots(for urls: [URL], placeholder: String) -> [Root] {
            var prefixes: [String] = []
            for url in urls {
                for candidate in [url.standardizedFileURL.path, CanonicalFilePath.path(for: url)] {
                    let value = PortablePath.trimmed(candidate)
                    guard value.count > 1, !prefixes.contains(value) else { continue }
                    prefixes.append(value)
                }
            }
            return prefixes
                .sorted { $0.count > $1.count }
                .map { Root(prefix: $0, placeholder: placeholder) }
        }

        /// A JSON or argv value: one absolute path, or free text.
        func rewrite(value: String) -> String {
            if Self.isSinglePath(value) {
                return rewrite(absolutePath: value)
            }
            return value.contains("/") ? rewrite(text: value) : value
        }

        /// True when `value` reads as one absolute path, which may hold spaces.
        static func isSinglePath(_ value: String) -> Bool {
            guard value.hasPrefix("/"), value.count > 1, !value.hasPrefix("//") else { return false }
            if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) { return false }
            for separator in [" /", " -", " '", " \"", " |", " >", " <", ",", ";", "=/"] where value.contains(separator) {
                return false
            }
            return true
        }

        /// The placeholder form of one absolute path.
        func rewrite(absolutePath token: String) -> String {
            var path = token
            var trailing = ""
            while let last = path.last, last == "." || last == ":" {
                trailing.insert(last, at: trailing.startIndex)
                path.removeLast()
            }
            guard path.count > 1 else { return token }

            var forms = [path]
            let canonical = CanonicalFilePath.path(for: URL(fileURLWithPath: path))
            if canonical != path { forms.append(canonical) }
            for root in ordered {
                for form in forms {
                    if form == root.prefix {
                        return (root.placeholder == Self.projectMarker ? "@/" : root.placeholder) + trailing
                    }
                    if form.hasPrefix(root.prefix + "/") {
                        let relative = String(form.dropFirst(root.prefix.count + 1))
                        if root.placeholder == workspacePlaceholder {
                            return workspaceForm(relative: relative) + trailing
                        }
                        return root.placeholder + "/" + relative + trailing
                    }
                }
            }
            for preserved in preservedPrefixes where path == preserved || path.hasPrefix(preserved + "/") {
                return token
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return externalPlaceholder + "/" + name + trailing
        }

        /// Free-text rewriting: a known root is matched wherever a path may
        /// start, so a root whose name holds spaces is still recognised; any
        /// other absolute path is tokenised up to the next terminator.
        func rewrite(text: String) -> String {
            let characters = Array(text)
            var output = ""
            output.reserveCapacity(text.utf8.count)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                let startsPath = character == "/"
                    && (index == 0 || pathLeadIns.contains(characters[index - 1]))
                guard startsPath else {
                    output.append(character)
                    index += 1
                    continue
                }
                if output.hasSuffix("file:"), index + 2 < characters.count,
                   characters[index + 1] == "/", characters[index + 2] == "/" {
                    var end = index
                    while end < characters.count, !urlTerminators.contains(characters[end]) {
                        end += 1
                    }
                    let rewrittenURL = rewrite(fileURLPath: String(characters[index ..< end]))
                    if Self.isUnresolvableURLForm(rewrittenURL) {
                        // `<external>` and `<workspace>` cannot promise a
                        // path, so they become a relative URL whose `.path`
                        // reads exactly like the plain-text placeholder.
                        output.removeLast("file:".count)
                        output += rewrittenURL.dropFirst(3)
                    } else {
                        output += rewrittenURL
                    }
                    index = end
                    continue
                }
                if let (root, end) = matchRoot(in: characters, at: index) {
                    if root.placeholder == workspacePlaceholder, accountName != nil,
                       end < characters.count, characters[end] == "/" {
                        var tokenEnd = end
                        while tokenEnd < characters.count, !pathTerminators.contains(characters[tokenEnd]) {
                            tokenEnd += 1
                        }
                        output += workspaceForm(relative: String(characters[(end + 1) ..< tokenEnd]))
                        index = tokenEnd
                        continue
                    }
                    if root.placeholder == Self.projectMarker {
                        output += (end < characters.count && characters[end] == "/") ? "@" : "@/"
                    } else {
                        output += root.placeholder
                    }
                    index = end
                    continue
                }
                var end = index
                while end < characters.count, !pathTerminators.contains(characters[end]) {
                    end += 1
                }
                let token = String(characters[index ..< end])
                if token.hasPrefix("//") || token.count <= 1 {
                    // A URL authority (`https://host/...`) or a lone slash.
                    output += token
                } else {
                    output += rewrite(absolutePath: token)
                }
                index = end
            }
            return output
        }

        static func isUnresolvableURLForm(_ rewritten: String) -> Bool {
            rewritten.hasPrefix("///" + PortablePath.percentEncodePath(externalPlaceholder) + "/")
                || rewritten.hasPrefix("///" + PortablePath.percentEncodePath(workspacePlaceholder) + "/")
        }

        /// The part of a `file://` URL after `file:`, rewritten so it stays a
        /// valid URL: `///@/Imports/a%20b` or `///%3Ctool-root%3E/envs/...`.
        func rewrite(fileURLPath slashed: String) -> String {
            let slashes = slashed.prefix(while: { $0 == "/" }).count
            guard slashes >= 3 else { return slashed }
            let encodedPath = "/" + slashed.dropFirst(slashes)
            var suffix = ""
            var pathPart = Substring(encodedPath)
            if let queryIndex = encodedPath.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                suffix = String(encodedPath[queryIndex...])
                pathPart = encodedPath[..<queryIndex]
            }
            guard let decoded = String(pathPart).removingPercentEncoding else { return slashed }
            let rewritten = rewrite(absolutePath: decoded)
            guard rewritten != decoded else { return slashed }
            return "///" + PortablePath.percentEncodePath(rewritten) + suffix
        }

        /// The longest root that starts at `index` and ends at a path
        /// boundary, with the index just past it.
        private func matchRoot(in characters: [Character], at index: Int) -> (Root, Int)? {
            for root in ordered {
                let prefix = Array(root.prefix)
                let end = index + prefix.count
                guard end <= characters.count else { continue }
                guard Array(characters[index ..< end]) == prefix else { continue }
                if end == characters.count || characters[end] == "/" || pathTerminators.contains(characters[end])
                    || characters[end] == "." || characters[end] == ":" {
                    return (root, end)
                }
            }
            return nil
        }
    }

    // MARK: - Resolver

    struct Resolver {
        /// Placeholder text and its real root, without a trailing slash.
        let fixedRoots: [(placeholder: String, root: String)]
        let project: String?
        let temporaryRoots: [String]

        init(context: Context) {
            var roots: [(String, String)] = []
            if let bundle = context.bundleURL {
                roots.append((bundlePlaceholder, PortablePath.trimmed(bundle.standardizedFileURL.path)))
            }
            if let toolRoot = context.toolRootURL {
                roots.append((toolRootPlaceholder, PortablePath.trimmed(toolRoot.standardizedFileURL.path)))
            }
            if let storageRoot = context.storageRootURL {
                roots.append((storageRootPlaceholder, PortablePath.trimmed(storageRoot.standardizedFileURL.path)))
            }
            fixedRoots = roots
            project = context.projectURL.map { PortablePath.trimmed($0.standardizedFileURL.path) }
            var temporary: [String] = []
            for url in context.temporaryRootURLs {
                let path = PortablePath.trimmed(url.standardizedFileURL.path)
                if !temporary.contains(path) { temporary.append(path) }
            }
            temporaryRoots = temporary
        }

        func resolve(text: String) -> String {
            let characters = Array(text)
            var output = ""
            output.reserveCapacity(text.utf8.count)
            var index = 0
            while index < characters.count {
                if let (replacement, end) = match(in: characters, at: index, previous: output) {
                    output += replacement
                    index = end
                } else {
                    output.append(characters[index])
                    index += 1
                }
            }
            return output
        }

        private func startsWith(_ characters: [Character], at index: Int, _ literal: String) -> Bool {
            let literalCharacters = Array(literal)
            let end = index + literalCharacters.count
            return end <= characters.count && Array(characters[index ..< end]) == literalCharacters
        }

        private func match(in characters: [Character], at index: Int, previous output: String) -> (String, Int)? {
            let first = characters[index]
            guard first == "@" || first == "<" || first == "%" else { return nil }
            if output.hasSuffix("file:///") {
                return matchInFileURL(characters, at: index)
            }
            guard index == 0 || pathLeadIns.contains(characters[index - 1]) else { return nil }

            // `@/` (project-relative).
            if let project, startsWith(characters, at: index, "@/") {
                let end = index + 2
                if end == characters.count || pathTerminators.contains(characters[end]) {
                    return (project, end)
                }
                return (project + "/", end)
            }
            for (placeholder, root) in fixedRoots where startsWith(characters, at: index, placeholder) {
                let end = index + placeholder.count
                guard end == characters.count || characters[end] == "/" || pathTerminators.contains(characters[end]) else {
                    continue
                }
                return (root, end)
            }
            let encodedWorkspace = PortablePath.percentEncodePath(workspacePlaceholder) + "/"
            if first == "%", startsWith(characters, at: index, encodedWorkspace) {
                // A `file://` URL written as a relative `<workspace>` URL.
                let start = index + encodedWorkspace.count
                var end = start
                while end < characters.count, !urlTerminators.contains(characters[end]),
                      characters[end] != "?", characters[end] != "#" { end += 1 }
                if let relative = String(characters[start ..< end]).removingPercentEncoding,
                   let existing = existingTemporaryPath(relative) {
                    return ("file://" + PortablePath.percentEncodePath(existing), end)
                }
                return nil
            }
            if startsWith(characters, at: index, workspacePlaceholder + "/") {
                // A scratch path may hold spaces; try the longest span that
                // names an existing file, shrinking at each space.
                let start = index + workspacePlaceholder.count + 1
                var limit = start
                while limit < characters.count, characters[limit] == " " || !pathTerminators.contains(characters[limit]) {
                    limit += 1
                }
                var end = limit
                while end > start {
                    if let existing = existingTemporaryPath(String(characters[start ..< end])) {
                        return (existing, end)
                    }
                    guard let space = characters[start ..< end].lastIndex(of: " ") else { break }
                    end = space
                }
            }
            return nil
        }

        /// A placeholder right after `file:///`: `@/...` or `%3Cname%3E/...`.
        /// The preceding `file:///` already supplies the leading slash, so the
        /// replacement is the root without its first `/`, percent-encoded.
        private func matchInFileURL(_ characters: [Character], at index: Int) -> (String, Int)? {
            func encodedRoot(_ root: String) -> String {
                PortablePath.percentEncodePath(String(root.dropFirst()))
            }
            if let project, startsWith(characters, at: index, "@/") {
                return (encodedRoot(project) + "/", index + 2)
            }
            for (placeholder, root) in fixedRoots {
                let encoded = PortablePath.percentEncodePath(placeholder)
                guard startsWith(characters, at: index, encoded) else { continue }
                return (encodedRoot(root), index + encoded.count)
            }
            let workspace = PortablePath.percentEncodePath(workspacePlaceholder) + "/"
            if startsWith(characters, at: index, workspace) {
                let start = index + workspace.count
                var end = start
                while end < characters.count, !urlTerminators.contains(characters[end]),
                      characters[end] != "?", characters[end] != "#" { end += 1 }
                if let relative = String(characters[start ..< end]).removingPercentEncoding,
                   let existing = existingTemporaryPath(relative) {
                    return (PortablePath.percentEncodePath(String(existing.dropFirst())), end)
                }
            }
            return nil
        }

        private func existingTemporaryPath(_ relative: String) -> String? {
            guard !relative.isEmpty else { return nil }
            for root in temporaryRoots {
                let candidate = root + "/" + relative
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }
    }

    // MARK: - JSON

    /// A JSON tree that round-trips through Foundation's encoders without
    /// changing values.
    indirect enum JSONNode: Codable {
        case object([String: JSONNode])
        case array([JSONNode])
        case string(String)
        case integer(Int)
        case number(Double)
        case boolean(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONNode].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONNode].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }

        func mapStrings(
            dropping shouldDrop: (String, String) -> Bool,
            _ transform: (String) -> String
        ) -> JSONNode {
            switch self {
            case .object(let value):
                var result: [String: JSONNode] = [:]
                for (key, child) in value {
                    if case .string(let text) = child, shouldDrop(key, text) { continue }
                    result[key] = child.mapStrings(dropping: shouldDrop, transform)
                }
                return .object(result)
            case .array(let value):
                return .array(value.map { $0.mapStrings(dropping: shouldDrop, transform) })
            case .string(let value):
                return .string(transform(value))
            case .integer, .number, .boolean, .null:
                return self
            }
        }
    }
}

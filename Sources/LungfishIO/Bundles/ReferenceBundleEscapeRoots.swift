// ReferenceBundleEscapeRoots.swift - Origin-scoped escape-root derivation for
// reference bundles (Item 1, hardened rule).
//
// A mapping VIEWER bundle symlinks its top-level payload directories (`genome/`,
// `annotations/`, `variants/`, `metadata/`) into an external SOURCE
// `.lungfishref`, and records that source in `manifest.originBundlePath`. The
// bundle-member validator would normally reject those symlinks as escapes. This
// helper derives the SINGLE trusted escape root (the source bundle) from
// `originBundlePath` — but ONLY when every hardened security constraint holds.
// If any check fails, it returns `[]`, restoring the strict (reject-all-escapes)
// behavior.
//
// The derivation lives in LungfishIO (Core -> IO layering is never violated):
// `BundleManifest.validatedBundleMemberURL` takes only a pure
// `allowedEscapeRoots: [URL]`; this file computes that value.
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public enum ReferenceBundleEscapeRoots {

    /// Derives the trusted escape roots for `bundleURL` given its `manifest`.
    ///
    /// Returns `[]` (strict behavior) unless ALL of the following hold:
    /// 1. `manifest.originBundlePath` is present and is a VALID relative bundle
    ///    path: not absolute, no `..`/`.`/empty component. For the `@/` form the
    ///    inner path is validated the same way.
    /// 2. The viewer bundle resolves inside a `.lungfish` project root, and the
    ///    origin resolves inside the SAME project root.
    /// 3. The resolved origin has extension `.lungfishref`, exists, its own
    ///    `manifest.validate()` passes, and its `identifier` equals the viewer's
    ///    `identifier` (identity authentication).
    /// 4. The origin is NOT an ancestor of the viewer bundle, and is not `/`,
    ///    `$HOME`, `/etc`, `/Users`, or a volume root.
    ///
    /// Depth is fixed at 1: the origin's own `originBundlePath` is never
    /// consulted (no transitive escape).
    public static func allowedRoots(
        forBundleAt bundleURL: URL,
        manifest: BundleManifest
    ) -> [URL] {
        guard let origin = manifest.originBundlePath, !origin.isEmpty else {
            return []
        }

        // (1) Validate the origin path string itself.
        guard let innerPath = validatedRelativeOriginPath(origin) else {
            return []
        }

        // (2) The viewer must live inside a `.lungfish` project.
        guard let projectRoot = FASTQBundle.findProjectRoot(from: bundleURL) else {
            return []
        }
        let resolvedProjectRoot = projectRoot.resolvingSymlinksInPath().standardizedFileURL

        // Resolve the origin. For `@/` resolve from the project root; otherwise
        // resolve the validated relative path against the viewer bundle URL.
        // We do NOT use FASTQBundle.resolveBundle's permissive legacy fallback.
        let resolvedOrigin: URL
        if origin.hasPrefix("@/") {
            resolvedOrigin = projectRoot
                .appendingPathComponent(innerPath, isDirectory: true)
                .standardizedFileURL
        } else {
            // `MappingViewerBundlePreparer.filesystemRelativePath` counts one
            // `..` per path component of the VIEWER BUNDLE itself (including
            // the bundle's own last component), i.e. it computes `innerPath`
            // as if walking ".." out of the bundle directory. Foundation's
            // `URL(fileURLWithPath:relativeTo:)` only agrees with that count
            // when `bundleURL` carries the `isDirectory` trailing-slash flag;
            // callers of `ReferenceBundle(url:)` do not reliably pass a
            // directory-flagged URL (e.g. URLs from file enumeration or a
            // search index), so a bare `bundleURL` silently cancels one path
            // component and resolves one directory too shallow. Rebuild an
            // explicitly directory-flagged URL from `bundleURL`'s own
            // (already standardized) path before resolving so the `..` count
            // always agrees with the preparer regardless of how `bundleURL`
            // was constructed.
            let bundleAsDirectory = URL(
                fileURLWithPath: bundleURL.standardizedFileURL.path,
                isDirectory: true
            )
            resolvedOrigin = URL(fileURLWithPath: innerPath, relativeTo: bundleAsDirectory)
                .standardizedFileURL
        }
        let canonicalOrigin = resolvedOrigin.resolvingSymlinksInPath().standardizedFileURL

        // (2 cont.) The origin must resolve INSIDE the same project root.
        guard isDescendantOrEqual(canonicalOrigin, of: resolvedProjectRoot) else {
            return []
        }

        // (3) Extension + existence + manifest identity authentication.
        //
        // These checks use `canonicalOrigin` (symlink-resolved), NOT
        // `resolvedOrigin`, for consistency with the containment logic below:
        // if the recorded origin path itself resolves through a top-level
        // symlink (e.g. a `.lungfishref` alias), the extension and existence
        // checks must see the SAME final target that containment and
        // manifest-loading operate on, not the pre-resolution link name.
        guard canonicalOrigin.pathExtension == "lungfishref" else {
            return []
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalOrigin.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        guard let originManifest = try? BundleManifest.load(from: resolvedOrigin),
              originManifest.validate().isEmpty,
              originManifest.identifier == manifest.identifier else {
            return []
        }

        // NOTE: `originManifest.identifier == manifest.identifier` is NOT a
        // provenance authenticator — it is a bundle-identity CONSISTENCY
        // check, not proof the origin genuinely produced this viewer. An
        // attacker who controls the origin path can ship a look-alike
        // `.lungfishref` at that path with the SAME `identifier` string
        // (identifiers are attacker-writable manifest fields, not signed).
        // The identifier match alone authenticates nothing. The actual
        // security boundary enforced here is the CONJUNCTION of: (i) the
        // resolved origin containment inside the SAME `.lungfish` project
        // root as the viewer (checked above), (ii) the resolved origin
        // carrying the `.lungfishref` extension and existing as a directory
        // (checked above), and (iii) file-identity containment of the fully
        // resolved candidate within the returned escape root (enforced by
        // `BundleManifest.validatedBundleMemberURL`'s
        // `isContainedByFileIdentity`, not by this function). Do NOT relax
        // the project-root constraint on the theory that identifier matching
        // already proves provenance — it does not.

        // (4) Reject dangerous / ancestor origins.
        let canonicalViewer = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard !isForbiddenRoot(canonicalOrigin),
              !isAncestorOrEqual(canonicalOrigin, of: canonicalViewer) else {
            return []
        }

        return [resolvedOrigin]
    }

    // MARK: - Origin string validation

    /// Validates the recorded origin path and returns the inner relative path to
    /// resolve (with the `@/` prefix stripped when present). Returns `nil` for
    /// any absolute path or a path containing `..`, `.`, or an empty component.
    private static func validatedRelativeOriginPath(_ origin: String) -> String? {
        let inner: String
        if origin.hasPrefix("@/") {
            inner = String(origin.dropFirst(2))
        } else {
            inner = origin
        }
        guard !inner.isEmpty, !inner.hasPrefix("/"), !inner.hasPrefix("~") else {
            return nil
        }
        let components = inner.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return inner
    }

    // MARK: - Path relationship helpers (string-based; inputs are pre-resolved)

    private static func isDescendantOrEqual(_ url: URL, of directory: URL) -> Bool {
        if url.standardizedFileURL.path == directory.standardizedFileURL.path {
            return true
        }
        let dirPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return url.path.hasPrefix(dirPath)
    }

    private static func isAncestorOrEqual(_ possibleAncestor: URL, of url: URL) -> Bool {
        isDescendantOrEqual(url, of: possibleAncestor)
    }

    private static func isForbiddenRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" || path.isEmpty { return true }
        let forbidden: Set<String> = [
            "/etc",
            "/private/etc",
            "/Users",
            "/System",
            "/var",
            "/private/var",
            "/tmp",
            "/private/tmp",
        ]
        if forbidden.contains(path) { return true }
        // Home directory.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path
        if path == home { return true }
        // Volume root (`/Volumes/<name>` with no further component).
        if path.hasPrefix("/Volumes/") {
            let remainder = path.dropFirst("/Volumes/".count)
            if !remainder.contains("/") { return true }
        }
        return false
    }
}

# Fork runtime identity audit

Read-only inspection, 2026-09-05. This ignored report is the only file written; no builds, credentials, production edits, scientific processing, or tests run. Read alongside `signing-forks.md`; the public release contract owns branding/trust, private profiles own signing credential selectors.

## Blocking findings

1. `Sources/LungfishCore/AppIdentity.swift` accepts only the three exact upstream name/bundle/channel tuples. A customized release contract can produce a signed fork that terminates on `LungfishAppIdentity.current`. Merely loosening the name check leaves all non-debug forks in upstream `Lungfish`, `.lungfish`, `.config/lungfish`, `com.lungfish` caches, `com.lungfish.secrets`, and `~/.nextflow`.
2. `.current` immediately returns `.stable` outside `Bundle.main.bundleURL.pathExtension == "app"`. A fork's embedded `lungfish-cli` therefore uses upstream state and Keychain even if the containing GUI is fixed. Resolving identity must precede lazy singleton construction in `ManagedStorageConfigStore`, `KeychainSecretStorage`, and other shared consumers. App helper modes run through `Sources/Lungfish/main.swift`; ensure their identity matches GUI as well.
3. `ManagedStorageConfigStore.currentLocation(environment:)` selects `legacyLocation()` for all non-debug identities when its JSON is absent; `resetToDefaultLocation()` removes the legacy database preference for all non-debug identities. Forks need an explicit `allowsUpstreamLegacyMigration == false`, independent of release channel. `isDebug` is not a storage compatibility policy.
4. `Sources/Lungfish/main.swift:SparkleUpdaterBridge.hasRequiredConfiguration` merely checks nonempty feed/key. Validate the updater configuration as one unit with the resolved identity; unknown/partial fork metadata must never enable a fallback upstream updater. Public key and feed still belong in standard Sparkle plist keys. Package validation must bind them to the public contract digest, as recommended in `signing-forks.md`.
5. Hardcoded upstream presentation/help routing: About website/title/copyright/tagline in `Sources/LungfishApp/App/AboutWindowController.swift`; documentation and release URLs in `AppDelegate+MenuActions.swift` (around 872/878); CLI overview URL in `Sources/LungfishCLI/LungfishCLI.swift`; Help name and fixed resource path in `Views/Help/HelpWindowController.swift`; help bundle identifier/name/title in `Resources/HelpBook/Lungfish.help/Contents/Info.plist`; main help registration in `Lungfish-Info.plist`. The main plist says `Lungfish Help`, while the helper and inner plist use `Lungfish Genome Explorer Help`: validate registration consistency rather than blindly preserving this mismatch for new products.

## Minimal public/runtime contract

Extend committed `config/release-contract.json`, consistent with the signing report's `identity.repository`, `identity.productSlug`, `identity.sparklePublicEdKey` and per-channel names/bundle IDs. Add a product identity kind (`upstream` or `fork`), a versioned public presentation object, and per-channel `runtimeNamespace`. Derive release-history URL from the declared repository, and declare optional website/documentation links explicitly. Fork initializer must remove upstream links/migration feeds unless intentionally selected, and supply distinct visible names, bundle IDs, namespaces, repository, and Sparkle key.

Generate one validated runtime dictionary into `Info.plist`, alongside standard CF/Sparkle keys; do not introduce an independently edited runtime config:

```json
{
  "LungfishIdentity": {
    "schemaVersion": 1,
    "kind": "fork",
    "productSlug": "example-genome",
    "repository": "example/example-genome",
    "runtimeNamespace": "org.example.genome.preview",
    "websiteURL": "https://example.org/genome",
    "documentationURL": "https://example.org/genome/docs",
    "releaseHistoryURL": "https://github.com/example/example-genome/releases"
  },
  "CFBundleIdentifier": "org.example.genome.preview",
  "CFBundleName": "Example Preview",
  "CFBundleDisplayName": "Example Genome Preview",
  "LungfishReleaseChannel": "preview"
}
```

Names remain authoritative in CF keys; avoid duplicate names inside the dictionary. Contract-only icon/about-logo paths can stage assets under existing filenames without renaming Swift modules or resource bundles. If full About branding is in scope, add optional `tagline` and distributor display label/copyright to the public presentation object; preserve third-party/open-source attribution separately. A fork must not automatically claim upstream funding or endorsement. Derive Help book title from display name and Help ID from bundle ID; fixed internal `Lungfish.help` folder can remain, but its registration and contents must be generated consistently.

Validation: recognized schema and kind; strict field types; reject unknown fields where practical; reject empty/control-character/unexpanded-placeholder names; validate ASCII reverse-DNS bundle/namespace with safe single-component path grammar (no slash, backslash, dot/dotdot component, whitespace, tilde, or percent-encoded path tricks); validate bounded names and slug; validate HTTPS URLs with host and no credentials; canonical repository release-history relationship; reject fork namespaces and bundle IDs in reserved upstream namespace families (`com.lungfish`, `org.lungfish` and descendants), not only the exact three IDs. All selected channel bundle IDs and runtime namespaces must be unique. `upstream` requires exact known tuples and legacy storage policy, never an arbitrary namespace. Runtime metadata errors must have a diagnostic path for CLI/packaging instead of silently adopting stable.

Compatibility: absent `LungfishIdentity` is accepted only for exact existing upstream tuples. Existing stable/preview/debug constants and tests retain their values. Package new upstream builds with an explicit upstream dictionary, while reading old app plists remains supported. A bare historical upstream SwiftPM CLI retains legacy stable behavior; a packaged fork CLI must always have runtime identity and cannot fall back to stable when it is malformed/missing.

## Storage policy

Keep all existing upstream persisted values exactly:

| Resource | Upstream stable and preview | Upstream debug | Fork namespace N |
|---|---|---|---|
| Application Support, Logs child | Lungfish | Lungfish Debug | N |
| Caches and temp child | com.lungfish | com.lungfish.debug | N |
| Container cache child | com.lungfish.containers | com.lungfish.debug.containers | N.containers |
| Config child under ~/.config | lungfish | lungfish-debug | N |
| Managed storage child under home | .lungfish | .lungfish-debug | .N |
| Keychain service | com.lungfish.secrets | com.lungfish.secrets.debug | N.secrets |
| Nextflow home | ~/.nextflow | ~/Library/Caches/com.lungfish.debug/nextflow | ~/Library/Caches/N/nextflow |

Use distinct fork namespaces per channel initially. No implicit migration, symlinking, discovery of upstream storage, or key copying. `LUNGFISH_STORAGE_ROOT` and `LUNGFISH_CONDA_ROOT` remain existing intentional overrides; isolated defaults cannot prevent a caller deliberately selecting the same data directory. Do not silently ignore documented overrides or alter scientific provenance semantics.

`UserDefaults.standard` in GUI already gets the app domain from bundle ID. Existing preference keys such as `com.lungfish.appSettings`, notification names, error domains, and OS logging subsystem strings do not inherently cross that boundary and need no mass rename. A fork standalone/embedded CLI requires an identity-selected defaults domain: use a narrow defaults provider for components touching preferences (notably `AppSettings` and `ManagedStorageConfigStore.legacyDefaults`), returning historical `.standard` for upstream and a fork suite under N for fork CLI. Decide explicitly whether GUI and CLI share a fork preference suite; simplest is N == selected bundle ID and same suite for both. Audit other `.standard` consumers before claiming complete CLI preference isolation.

Existing central property consumers include `TempFileManager`, `ManagedStorageLocation`, `ManagedStorageConfigStore`, `AppSettings`, `MetadataPresetStore`, `OperationFailureReportStore`, `RecipeRegistry`, `ProjectWindowStateStore`, `AppleContainerRuntime`, `WorkflowEngineLaunch`, `TaxTriagePipeline`, and PBAA's process runner. Most should need no path rewrites once identity resolves correctly; test their derived outputs and migration gates. CondaManager consumes managed storage; do not rename env/tool identities or data schemas.

## Embedded and standalone CLI resolution

Introduce testable `RuntimeAppIdentityResolver.resolve(mainBundleInfo:mainBundleURL:executableURL:...) throws -> LungfishAppIdentity` rather than mutable global injection or ambient environment identity. Reuse/extract the canonical executable/enclosing-app discovery used by `RuntimeResourceLocator`; do not use cwd, PATH search, or inherited env to choose fork identity. Resolve actual executable symlinks and require it to be contained in the app's canonical Contents tree; reject malformed enclosing app metadata rather than falling back. GUI and embedded CLI both load the enclosing app plist.

A separately distributed fork CLI needs a mandatory, package-installed metadata resource or compiled identity fingerprint that survives relocation. Recommended v1 scope: embedded CLI and symlinked installed CLI resolve the owning app; copying just the binary out is unsupported and must fail if it is a fork build. Accomplish fail-closed behavior with a build-generated public identity marker/fingerprint in each fork executable, compared against resolved app metadata. This also detects accidentally packaging an upstream CLI into a fork app. If supporting standalone archives now, include a bounded canonical executable-relative runtime metadata file and validate its fingerprint against the executable; missing metadata never becomes upstream. Do not recompile branding into all scientific modules: the marker belongs in a tiny generated identity source/resource module and runtime resolver.

The build report should account for this identity marker in build-cache inputs: forks cannot reuse an upstream CLI binary unchanged if fail-closed copied-binary behavior is required. Pure enclosing-app discovery alone fixes embedded behavior but cannot distinguish an extracted fork binary from historical bare upstream CLI; this is a real design choice, not something plist validation solves.

## Concrete implementation interfaces and validation

- `Sources/LungfishCore/AppIdentity.swift`: typed identity kind/storage policy, namespace and presentation fields, strict backward-compatible parser, upstream constants; factor runtime resolver if needed.
- New small `Sources/LungfishCore/RuntimeAppIdentityResolver.swift` plus identity build marker resource/source: canonical packaged executable resolution and typed errors; expose a read-only diagnostic identity description.
- `ManagedStorageConfigStore.swift`: legacy migration policy; fork defaults provider; retain explicit runtime overrides.
- `Lungfish-Info.plist`, help inner plist and release/debug builders: generate runtime dictionary and synchronized Help keys from the same contract; bind metadata/hash in release receipt.
- `Sources/Lungfish/main.swift`: parse validated update configuration before Sparkle initialization; CLI/helper entry points resolve identity before shared services and emit actionable startup error.
- `AboutWindowController.swift`, `AppDelegate+MenuActions.swift`, `HelpWindowController.swift`, `LungfishCLI.swift`: use typed presentation links/branding. Internal resource folder names and public format identifiers stay stable.
- Extend `Tests/LungfishCoreTests/AppIdentityTests.swift`: exact golden upstream paths and identities; valid fork per channel; reserved namespaces; unknown/missing/type-invalid schema fields; control/path traversal names; channels/IDs mismatch; partial updater config.
- Extend `KeychainSecretStorageIdentityTests.swift`: injected service selection only, no real Keychain access; fork differs from upstream and other fork/channel; preserve upstream shared stable/preview service.
- Resolver fixture tests: GUI, helper, embedded CLI, symlink CLI, moved app, spaces in path, malformed enclosing metadata, resource symlink escape, missing fork metadata, wrong executable marker; historical bare upstream CLI stays stable.
- Storage tests: fake home/defaults preseeded with upstream config and secrets selectors; fork reads/writes only its roots and never migrates/removes upstream legacy preference; default Nextflow/cache/conda roots isolate; explicit documented overrides remain honored.
- Presentation tests (`AppIdentityPresentationTests`, `HelpSystemTests`) assert fork About/menu/links/help routing; upstream names remain unchanged. Package fixture test checks app, help, CLI marker, selected feed/key, and receipt all agree after relocation. A candidate diagnostic mode should report effective app/CLI identity without launching any scientific workflow or touching credential values.

No changes to `.lungfish*` extensions/UTIs, manifest identifiers, input/output provenance formats, tool version identities, or reproducible argv conventions are needed for this work. New release artifacts need the release receipt, while scientific workflow provenance remains governed by the existing requirements.

## Implementation refinement after root design review

The root draft is consistent with this audit. Prefer this smaller v1 runtime surface over the illustrative nested metadata framework above:

- Retain existing CFBundleDisplayName, CFBundleName, CFBundleIdentifier, LungfishReleaseChannel.
- Forks add `LungfishIdentitySchemaVersion` (integer 1) and `LungfishRuntimeNamespace` (validated reverse-DNS path component); require these keys together. Existing upstream plists remain unchanged. Their absence accepts only known upstream tuples for app bundles. Presence requires a non-upstream bundle ID and namespace; no separate runtime kind or arbitrary storage policy fields. Derive `isFork` and `allowsUpstreamLegacyMigration` from this validated representation.
- Optional product URLs: `LungfishWebsiteURL`, `LungfishDocumentationURL`, `LungfishReleaseHistoryURL`; HTTPS with host, no credentials. Fork missing links are absent/disabled, never implicitly upstream. The public contract still owns repository/key/feed and validates their relationships before rendering the plist. Runtime does not need a second repository/slug schema.
- Store the same compact full identity plist in CLI `__TEXT,__info_plist` using the native Xcode setting requested by root, `CREATE_INFOPLIST_SECTION_IN_BINARY`; coordinate a SwiftPM fork Debug linker section with the build team. Full identity in the executable means a copied CLI retains its fork namespace without a sidecar or generated Swift constants. Keep scientific configuration/version declarations unchanged. Identity plist is a linker/build-cache input.

Minimal API: retain `LungfishAppIdentity.from(infoDictionary:) throws`, add optional validated `runtimeNamespace` and product URL properties; preserve all existing upstream constants/property values. Add an internal pure resolver `resolve(mainAppInfo:embeddedExecutableInfo:enclosingAppInfo:) throws -> LungfishAppIdentity` plus a small production adapter that discovers the canonical executable, reads its embedded plist, and loads an enclosing app plist when appropriate. Tests pass dictionaries directly. Do not introduce a global mutable identity registry.

Resolution: GUI app parses its app plist. Fork CLI with embedded metadata parses that independently; if enclosed in an app, require its identity tuple/namespace to match the enclosing app. Copied fork CLI uses the embedded identity. Missing or malformed fork section, malformed enclosing fork app, or conflicting dictionaries throws. An upstream CLI accidentally copied into a fork app must fail rather than silently adopt upstream state. Historical bare upstream CLI can still return stable only when no fork metadata or enclosing fork app exists. Preserve existing upstream non-app behavior unless root explicitly approves changing upstream Debug CLI storage; adopting the enclosing Debug identity would change its historical stable paths.

Read executable section explicitly if needed instead of assuming Foundation exposes it uniformly for every bundle context. Bind the main image only (not an arbitrary loaded dependency), bound plist size, and use PropertyListSerialization plus the same parser. Build acceptance verifies effective identity from an actual relocated GUI/embedded CLI/copied CLI, not solely injected dictionary unit tests. This section supersedes the earlier hash-marker/sidecar suggestion for this implementation.

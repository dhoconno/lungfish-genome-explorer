# Slice A Implementation Note: Core/AppKit Boundary

Date: 2026-05-16
Branch: `codex/wave2-core-appkit-boundary`
Base: `codex/wave2-integrated-fixes` at `8d44f77a`

## Scope

Remove AppKit and SwiftUI dependencies from `LungfishCore` color/settings models while preserving the existing persisted hex-string settings format and AppSettings main-actor singleton behavior.

Owned files:

- `Sources/LungfishCore/Models/SemanticColors.swift`
- `Sources/LungfishCore/Models/SequenceAppearance.swift`
- `Sources/LungfishCore/Models/AppSettings.swift`
- new Core color value type under `Sources/LungfishCore/Models/`
- app-owned AppKit adapters under `Sources/LungfishApp/Support/`
- focused Core tests for color value behavior and settings persistence

## Design

Core will expose a Foundation-only `HexColor` value for parsed RGB colors and keep persisted settings as `#RRGGBB` strings. `SemanticColors` will provide canonical `HexColor` constants and default hex maps. `SequenceAppearance` will provide hex-oriented read/write APIs, with invalid or missing values falling back to gray.

AppKit behavior will move to `LungfishApp` extensions that convert `HexColor`, `SequenceAppearance`, `SemanticColors`, and `AppSettings` values to `NSColor`. UI call sites can continue to ask for `NSColor` through app-owned adapters, while CLI/Core consumers avoid AppKit linkage.

`AppSettings` remains `@Observable`, `@MainActor`, and singleton-backed. Only the AppKit helper methods move out of Core; the persisted `annotationTypeColorHexes` field and default values stay unchanged.

## Tests

Use TDD by first changing Core tests to assert the new Foundation-only color behavior:

- `SequenceAppearance` returns `HexColor` values, preserves default hex strings, accepts lowercase bases, parses short/long hex, and falls back to gray for invalid or missing values.
- `AppSettings` exposes annotation color hex/default behavior without `NSColor` in Core tests.
- `HexColor` normalizes parsed values and round-trips through `Codable`.

Focused verification will then run the commands listed in the Wave 2 Slice A spec.

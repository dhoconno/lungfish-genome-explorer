# Xcode 27 toolchain

Lungfish builds with Xcode 27.x, Swift 6.4 or later within Swift 6, and the macOS 27 SDK. The app deployment target remains macOS 26.0 on Apple silicon. Compiler version, SDK version, Swift language mode, and minimum runtime are separate settings: `SWIFT_VERSION=6.0` and the package's `swift-tools-version: 6.2` remain intentional.

## Build and test compatibility

SwiftPM uses the supported Swift Build engine. Debug packaging, test discovery/execution, dependency verification and graphical-test helpers explicitly select `--build-system swiftbuild`. Executable consumers query `swift build` with the same engine/configuration and `--show-bin-path`; `.build/debug` and native engine triples are not portable product locations.

The gate records the selected engine for every discovery and execution command. Packaging must copy the engine's actual resource bundles and verify the relocated app while compiler resources are unavailable. Missing products or incomplete test discovery fail closed; deprecated engines are not fallbacks.

The shared `scripts/release/swiftpm_build.py` options also forward the selected SDK to the Darwin linker with `-Xclang-linker -isysroot`. The installed Swift driver passes `--sysroot` to Clang; in link-only invocations that selected the SDK 27 files but stamped SDK 26. An explicit `-isysroot` fixes SDK inference without changing the macOS 26 minimum. Project-level inherited Swift flags apply the same input to Xcode builds. Verify the actual GUI and CLI load commands after linking; do not rewrite their metadata after the build.

Release app compilation continues through the existing Xcode build graph. Its compiler cache fingerprint includes the exact Xcode build, Swift identity, SDK identity, deployment target and recipe inputs. The first build with a new toolchain is cold; old compiler caches and release receipts are not evidence for a new build. Scientific operation provenance continues to record the actual selected runtime and tool paths.

## CI

The `xcode-27` GitHub image supplies the required compiler on macOS 26. The ordinary `macos-26` image currently defaults to Xcode 26.6. GitHub labels the Xcode 27 image a public preview, with potential availability and queueing variability. CI remains advisory; local release evidence retains its existing authority.

## Migration tradeoffs

- New compiler diagnostics and SDK behavior can expose previously unnoticed issues. Keep minimum-OS and portability tests; do not increase deployment targets just to suppress compiler errors.
- Fresh compiler caches cost build time and disk space. Continue using explicit local build-retention maintenance.
- SDK 27 compilation and the macOS 26 deployment target cover build compatibility; actual macOS 27 runtime qualification must be recorded separately when that OS is available.
- A toolchain change does not update installed applications, publish a release, or migrate scientific dependency environments by itself.

## References

- [Apple Xcode SDK and system requirements](https://developer.apple.com/xcode/system-requirements)
- [Apple Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- [GitHub Xcode 27 runner announcement](https://github.com/actions/runner-images/issues/14404)
